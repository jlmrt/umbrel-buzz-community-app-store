# Buzz Umbrel Community App Store

> [!CAUTION]
> **NOT READY FOR INSTALLATION.** This package includes startup-chain
> corrections that have not yet passed a complete clean umbrelOS runtime test.
> Do not install or use this package with real data until that test succeeds.

This Community App Store packages Block's Buzz relay for umbrelOS with
PostgreSQL, Redis, MinIO, persistent git storage, and a small configuration UI.
It uses the official Buzz relay image and never needs a user's Nostr private
key.

## Install

Do not install until the warning above is removed by a corrected,
runtime-tested release.

1. In umbrelOS, open **App Store** -> **Community App Stores**.
2. Add `https://github.com/jlmrt/umbrel-buzz-community-app-store`.
3. Install **Buzz Relay** and open it from the Umbrel launcher.
4. Sign in through Umbrel and complete the guided setup.

## Configure

Enter the relay owner's `npub` or 64-character hexadecimal public key, then
choose **Local testing** or **Public community**. Local testing uses the
Community URL discovered from Umbrel. Public community asks only for the final
root `wss://` address after the operator has configured TLS and WebSocket
forwarding. This selects the canonical Community URL once; it is not a mode
that can later promote or migrate the same community. Media and allowed-origin
values are derived automatically.

The page rejects `nsec` values. Never paste a Nostr private key into the app,
repository, logs, or support messages. Raw 64-character hex is ambiguous, so
the page requires confirmation that it is public-key material.

The relay does not initialize until a valid public owner key and an explicit
canonical URL are saved. The canonical URL must exactly match the client-facing
URL, including scheme, host, and non-default port, because it participates in
NIP-42 authentication. The request `Host` must also be preserved.

After saving, the admin page displays the exact Community URL. In Buzz Desktop,
choose **Add a community** -> **Join an existing community**, paste it into
**Community URL or invite link**, and select **Join community**. Buzz Desktop
must be using the configured owner identity. Its optional **Use an API token**
control is not needed: this package uses signed NIP-42/NIP-98 authentication and
keeps closed relay membership enforcement enabled.

The relay allows the official Buzz Desktop webview origins so Desktop can read
the join policy before opening its WebSocket. This does not bypass Nostr
authentication or membership checks.

After an in-place update, hard-refresh the admin page if an Umbrel webview still
shows an older form. If the Local Community URL is unavailable, restart Buzz
Relay from Umbrel and reopen it. A restart preserves configuration and relay
data; do not uninstall the app or enter internal service addresses.

Buzz uses the URL and `Host` as the community boundary. The admin page locks the
canonical Community URL after initialization and rejects attempts to change it.
A different URL is a different Buzz community, not an editable network setting.

Changing the owner requires typing `RESET` and confirming a full reset. It
deletes PostgreSQL, Redis, MinIO, git data and cache, and the generated relay
identity. Create and download a backup first.

## Endpoints And Public Access

This package deliberately separates administration from relay traffic:

- **Admin:** Umbrel app port `38633`, routed through the standard Umbrel App
  Proxy with Umbrel authentication. The launcher opens this surface. Do not
  forward or publish this port.
- **Relay:** host port `38634`, mapped directly to Buzz HTTP and WebSocket
  traffic. It does not serve the configuration UI and is not protected by the
  Umbrel App Proxy; Buzz enforces its own Nostr authentication rules.

For trusted local testing, clients can use:

```text
ws://<umbrel-host>:38634
http://<umbrel-host>:38634/media
```

Buzz does not terminate TLS. Public DNS, firewalling, origin security, HTTPS,
and WSS termination are the operator's responsibility. A public proxy or tunnel
must target relay port `38634`, never admin port `38633`, preserve the original
`Host`, and support WebSocket upgrades. Follow the
[Umbrel App Framework](https://github.com/getumbrel/umbrel-apps#advanced-configuration)
and the chosen proxy or tunnel provider's authoritative documentation.

## Data And Recovery

Persistent state is under `~/umbrel/app-data/buzz-relay/data/`:

- `config/`: public settings, reset state, and generated relay secrets
- `postgres/`, `redis/`, and `minio/`: database, cache, and object data
- `git/` and `git-cache/`: repositories and pack cache
- `backups/`: the latest operator-created export archive

The authenticated admin page can create a local export. It pauses relay writes,
stops MinIO, makes a consistent PostgreSQL custom-format dump, and archives the
generated relay identity, configuration, object storage, and git repositories.
Redis and git cache are excluded because they are rebuilt. The archive includes
private content and secrets; download it, verify the displayed SHA-256, and
store it encrypted. Creating an export requires free space for staging and is
limited to 50 GiB of source data by default. The latest export stays in
`data/backups/` until replaced or the app is uninstalled; that directory is
excluded from umbrelOS system backups to avoid recursively backing it up.

**App-level archive restore is not implemented.** A safe restore must validate
the archive, migrate credentials, restore ownership, coordinate every service,
and roll back on failure. It will remain unavailable until a destructive clean
device recovery test proves that path.

Umbrel derives `APP_PASSWORD` from the Umbrel seed. The current supported
low-risk recovery path remains an umbrelOS same-seed full-system restore or this
manual stopped-tree procedure:

1. Stop Buzz Relay and record the package version and image digest.
2. Back up the complete `~/umbrel/app-data/buzz-relay/` tree while stopped,
   preserving owners and permissions.
3. Restore the same package version on an Umbrel installation using the same
   seed, then restore the complete stopped app tree.
4. Start the app and verify setup status, NIP-11, NIP-42 login, media access,
   and git data before upgrading.

An app-data-only restore to a different-seed host requires credential migration
or a tested logical import and is not supported by this package. Use the
umbrelOS **Backups** feature for supported full-device backup and recovery.

## Operations

The authenticated admin page shows relay version and uptime, restart state,
PostgreSQL/Redis/MinIO connectivity, aggregate member/channel/message/event
counts when upstream metrics are available, storage totals, and the time when
event activity was last observed. These are metadata-only aggregates; the page
does not query or display message bodies, profiles, media names, member keys, or
other private content. Admin APIs remain behind Umbrel App Proxy and are never
served on relay port `38634`.

## Security

- The relay uses closed membership mode with NIP-42/NIP-98 authentication.
- Media reads require Blossom kind `24242` authorization and membership.
- External push delivery is disabled by default.
- Buzz content is not made end-to-end encrypted by this package.
- Protect the Umbrel host, admin port, relay origin, generated secrets, seed,
  and backups.

## Updates And Validation

The Buzz image is pinned by tag and immutable digest. The optional upstream
monitor opens review pull requests and never applies updates automatically; see
[upstream monitoring](docs/upstream-monitoring.md).

Run static checks and the pinned current Umbrel linter with:

```bash
./scripts/validate.sh
./scripts/run-umbrel-lint.sh
```

Static validation is not runtime validation. A clean umbrelOS install, initial
setup, restart, destructive reset, data-preserving upgrade, recovery, NIP-42,
media, git, and public WSS flow must pass before the warning at the top can be
removed.

## References

- [Block Buzz](https://github.com/block/buzz)
- [Buzz production Compose bundle](https://github.com/block/buzz/tree/main/deploy/compose)
- [Umbrel App Framework](https://github.com/getumbrel/umbrel-apps)
