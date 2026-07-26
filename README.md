# Buzz Umbrel Community App Store

This is an Umbrel Community App Store for running Block's Buzz relay on
umbrelOS. The package deploys the official Buzz relay image plus PostgreSQL,
Redis, MinIO, and persistent git storage.

The repository intentionally contains no Nostr private key. On first run, the
relay refuses to start until you provide the public Nostr key that should own
and administer the Buzz relay.

## Install On Umbrel

1. In umbrelOS, open **App Store**.
2. Open **Community App Stores** and add this repository URL:
   `https://github.com/jlmrt/umbrel-buzz-community-app-store`
3. Install **Buzz Relay**.
4. SSH into the Umbrel host and set the owner public key:

```bash
mkdir -p ~/umbrel/app-data/buzz-relay/data/config
printf '%s\n' '<64-character-hex-nostr-public-key>' \
  | tee ~/umbrel/app-data/buzz-relay/data/config/relay-owner-pubkey >/dev/null
umbreld client apps.restart.mutate --appId buzz-relay
```

Use the hex public key for the Nostr account that should own the relay. If you
only have an `npub`, convert it to its 64-character hex public key with your
Nostr client or a trusted offline tool first. Do not use an `nsec` or any
private key.

## Public HTTPS/WSS

Buzz clients need a stable relay URL. For production, create DNS such as
`buzz.example.com`, terminate TLS in your reverse proxy, and proxy to:

```text
http://<umbrel-lan-ip>:38633
```

The proxy must support WebSocket upgrades and large request bodies for media
and git operations. Before inviting members, set the public URLs:

```bash
printf '%s\n' 'wss://buzz.example.com' \
  | tee ~/umbrel/app-data/buzz-relay/data/config/relay-url >/dev/null
printf '%s\n' 'https://buzz.example.com/media' \
  | tee ~/umbrel/app-data/buzz-relay/data/config/media-base-url >/dev/null
printf '%s\n' 'https://buzz.example.com' \
  | tee ~/umbrel/app-data/buzz-relay/data/config/cors-origins >/dev/null
umbreld client apps.restart.mutate --appId buzz-relay
```

Changing `relay-url` later changes the community host Buzz derives from the
URL, so set the final WSS URL before real use.

## What Runs

- `relay`: `ghcr.io/block/buzz:sha-e6c90bb`
- `postgres`: PostgreSQL 17
- `redis`: Redis 7 with AOF enabled
- `minio` and `minio-init`: S3-compatible media/object storage and bucket setup

Persistent data lives under `~/umbrel/app-data/buzz-relay/data/`:

- `config/`: owner public key, relay URL files, generated relay secrets
- `postgres/`: Buzz database
- `redis/`: Redis AOF data
- `minio/`: Buzz media and object storage bucket data
- `git/`: persistent git repository working/storage path
- `git-cache/`: persistent git pack cache

## Admin Commands

After the relay has started once, the package provides a helper that loads the
generated relay signing key for Buzz's admin CLI:

```bash
docker exec -it buzz-relay_relay_1 umbrel-buzz-admin list-members
docker exec -it buzz-relay_relay_1 umbrel-buzz-admin add-member --pubkey <npub-or-hex> --role admin
docker exec -it buzz-relay_relay_1 umbrel-buzz-admin remove-member --pubkey <npub-or-hex>
```

The helper uses Buzz's relay private key, not a user's Nostr private key.

## Backup And Restore

Back up `~/umbrel/app-data/buzz-relay/data/` while the app is stopped, or take
coordinated snapshots of Postgres, MinIO, and git state from the same maintenance
window. The most important files are:

- `config/generated.env`: Buzz relay identity and git hook HMAC secret
- `config/relay-owner-pubkey`, `config/relay-url`, `config/media-base-url`
- `postgres/`, `minio/`, and `git/`

Restoring without `config/generated.env` rotates the relay identity. Restoring
Postgres without matching MinIO/git data can leave media or repository pointers
dangling.

## Upgrades

This package pins the Buzz relay image to the verified upstream commit tag
`sha-e6c90bb` from `block/buzz`. To upgrade, update the image tag and digest in
`buzz-relay/docker-compose.yml`, review upstream `deploy/compose/`, then let
Umbrel update the app store. Do not rotate `config/generated.env` during an
upgrade.

After the first working Umbrel install has been proven, maintainers can enable
the conservative upstream monitor in [docs/upstream-monitoring.md](docs/upstream-monitoring.md).
It opens review pull requests for Block Buzz upstream changes; it never applies
updates blindly.

## Security Notes

- Buzz is configured in closed relay mode:
  `BUZZ_REQUIRE_AUTH_TOKEN=true` and `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`.
- The Umbrel app proxy auth header is disabled for Buzz so external Buzz clients
  can perform NIP-42/NIP-98 auth directly.
- Postgres, Redis, and MinIO are not published as host ports by this package.
- Use HTTPS/WSS for public access. Do not expose the raw HTTP relay port to the
  internet.
- Buzz content is not end-to-end encrypted by this package. Treat the Umbrel
  host, Postgres volume, MinIO data, and backups as sensitive.

## Upstream References

- Buzz: https://github.com/block/buzz
- Buzz production Compose bundle: https://github.com/block/buzz/tree/main/deploy/compose
- Umbrel Community App Store template: https://github.com/getumbrel/umbrel-community-app-store
