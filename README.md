# Buzz Umbrel Community App Store

> [!CAUTION]
> **NOT READY FOR INSTALLATION.** The current Buzz Relay Umbrel package has a
> confirmed PostgreSQL authentication/startup defect that causes the relay to
> restart-loop during first initialization. Do not install or use this package
> with real data. A corrected release will follow after clean umbrelOS runtime
> testing.

This Community App Store packages Block's Buzz relay for umbrelOS with
PostgreSQL, Redis, MinIO, persistent git storage, and a local configuration
page. It uses the official Buzz relay image and never needs a user's Nostr
private key.

> **Validation status:** installation is currently blocked by the confirmed
> PostgreSQL defect above. Static tests and the official Umbrel app linter are
> part of this repository, but the package must pass a clean umbrelOS install,
> initialization, upgrade, owner reset, and backup restore before it is ready.

## Install On Umbrel

**Do not follow these installation steps until a corrected, runtime-tested
release removes the warning at the top of this document.**

1. In umbrelOS, open **App Store** -> **Community App Stores**.
2. Add `https://github.com/jlmrt/umbrel-buzz-community-app-store`.
3. Install **Buzz Relay**, then open it from the Umbrel launcher.
4. Enter the relay owner's `npub` or 64-character hexadecimal public key. The
   page validates the format and displays both equivalent public forms.
5. Explicitly confirm the canonical relay URL, media URL, and allowed origins,
   then select **Save and start relay**.

The relay does not bootstrap until both a valid public owner key and an
explicit canonical relay URL have been saved. The suggested local URL is only a
prefill; review it before submitting.

The setup page rejects `nsec` values. Never paste a Nostr private key into the
page, repository, app configuration, logs, or support messages. A raw
64-character hex value is inherently ambiguous, so the page requires explicit
confirmation that it is a public key before saving it.

Umbrel's manifest port, exposed to Compose as `APP_PROXY_PORT`, is `38633` for
this package. One internal gateway serves:

- `/setup/`: the always-available local configuration page
- every other path: Buzz HTTP, WebSocket, media, and git traffic

The app proxy authentication header is disabled because native Nostr clients
must reach Buzz directly. The setup page therefore has no Umbrel login of its
own and must remain restricted to a trusted local network.

## Local And Trusted-Network Use

Buzz desktop defaults to `ws://localhost:3000`. That is appropriate when a
development relay runs on the same computer. For this Umbrel package, a
trusted-LAN test URL is normally:

```text
ws://<umbrel-lan-name-or-ip>:38633
```

Use the corresponding media URL and browser origin:

```text
http://<umbrel-lan-name-or-ip>:38633/media
http://<umbrel-lan-name-or-ip>:38633
```

Plain `ws://`/`http://` does not encrypt traffic. Use it only for localhost,
local development, or deliberate testing on a trusted network. The Buzz relay
does not terminate or enforce TLS itself. An Internet-facing relay requires a
TLS reverse proxy or tunnel and must use `wss://`/`https://`.

The configured relay URL must exactly match the URL clients use, including the
scheme, hostname, and non-default port. The URL participates in NIP-42
authentication; a client signing for one URL will be rejected when the relay
expects another. Buzz also scopes communities by request host. Changing the
configured relay URL and then using its matching `Host` can seed or select a
different community. An unconfigured request host fails closed.

Cloudflare is optional. Any correctly configured HTTPS/WSS reverse proxy can
provide public TLS.

## Owner Changes And Reset

The owner can be set without a private key. Changing it after initial setup is
intentionally destructive because membership and application state are bound
to the deployment.

The setup page displays a full-reset warning, requires a confirmation checkbox,
and requires typing `RESET`. Applying the change coordinates a graceful relay
shutdown and resets:

- PostgreSQL data
- Redis data
- MinIO objects
- git repositories and pack cache
- the generated relay signing key and git-hook secret

The new public owner key is promoted only after PostgreSQL, Redis, and MinIO
have restarted successfully. Keep a backup if any existing data may be needed.

Changing only the canonical hostname does not erase data, but the new host
selects or creates a different Buzz community. Treat a host change as an
application migration and test it before inviting users.

## Public HTTPS/WSS With Cloudflare

Cloudflare can proxy Buzz, but it is not required. Choose one of these paths:

- **Proxied DNS plus a reverse proxy:** the router exposes HTTPS port `443` to
  Caddy, NGINX, Traefik, or another reverse proxy, which forwards internally to
  Umbrel port `38633`.
- **Cloudflare Tunnel:** `cloudflared` publishes a hostname and forwards it to
  Umbrel port `38633` without an inbound router port.
- **DNS only:** Cloudflare provides DNS while a reverse proxy and public CA
  certificate handle TLS directly.

### Option A: Proxied DNS And A Reverse Proxy

1. In Cloudflare DNS, create an `A` record for the relay hostname pointing to
   the public IPv4 address. Add an `AAAA` record only when inbound IPv6 routing
   is configured. Use a dynamic-DNS updater if the address changes.
2. Set **Proxy status** to **Proxied** (orange cloud). A DNS-only record exposes
   the origin address and bypasses Cloudflare's HTTP proxy. See Cloudflare's
   [proxy status documentation](https://developers.cloudflare.com/dns/proxy-status/).
3. Run a reverse proxy on the local network. Forward router TCP port `443` only
   to that proxy. Forward the relay hostname to
   `http://<umbrel-lan-ip>:38633`, preserve the original HTTP `Host` header
   exactly, support HTTP/1.1 WebSocket upgrades, and allow long-lived
   connections. Do not rewrite the host to the Umbrel LAN address.
4. Block `/setup` and `/setup/` at the public reverse proxy. Administration is
   intentionally local-only; the relay root and protocol paths remain public.
5. Install a public certificate or Cloudflare Origin CA certificate on the
   reverse proxy. Select **SSL/TLS -> Full (strict)** so Cloudflare validates the
   origin certificate. Do not use Flexible mode. See Cloudflare's
   [Full (strict) requirements](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
   and [Origin CA guide](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/).
6. Confirm **Network -> WebSockets** is enabled. Cloudflare supports proxied
   WebSockets, but edge restarts or idle timeouts can close a connection;
   clients must reconnect. See the official
   [WebSockets notes](https://developers.cloudflare.com/network/websockets/).
7. Create a Cache Rule that bypasses cache for the complete Buzz hostname.
   Buzz serves authenticated API, media, and repository traffic; do not apply a
   broad "Cache Everything" rule.
8. Restrict the origin so port `38633` is reachable only from the trusted LAN.
   For a directly reachable proxied origin, expose only HTTPS and restrict it to
   Cloudflare's published IP ranges; Authenticated Origin Pulls can add origin
   authentication.

Cloudflare's standard proxy does **not** proxy port `38633` at its edge. It
accepts a supported public HTTP/HTTPS port such as `443`, then the local reverse
proxy forwards internally. See Cloudflare's
[network port list](https://developers.cloudflare.com/fundamentals/reference/network-ports/).

A minimal NGINX routing shape is:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    server_name buzz.example.com;

    client_max_body_size 100m;

    location = /setup { return 404; }
    location ^~ /setup/ { return 404; }

    location / {
        proxy_pass http://<umbrel-lan-ip>:38633;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
```

Replace the example hostname and placeholders. Configure certificate paths with
the reverse proxy's normal TLS tooling.

### Option B: Cloudflare Tunnel

1. Run `cloudflared` on a machine that can reach the Umbrel LAN address.
2. Create a tunnel and a **Published application** route for the relay hostname.
3. Set the service URL to `http://<umbrel-lan-ip>:38633`. Cloudflare terminates
   public TLS and carries traffic through the outbound tunnel; no inbound router
   port is required. See Cloudflare's
   [published application guide](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/).
4. Add a Cloudflare WAF custom rule that blocks paths beginning with `/setup`
   for the public hostname. A Tunnel publishes every path unless a policy blocks
   it.
5. Do not place an interactive Cloudflare Access login in front of the relay
   unless every Buzz client can satisfy that separate authentication layer.
   An Access challenge can prevent native WebSocket clients from connecting.

### Configure Buzz For The Public Hostname

Open **Buzz Relay** from the Umbrel launcher over the LAN and set all three
values together:

```text
Relay URL:       wss://buzz.example.com
Media base URL:  https://buzz.example.com/media
Allowed origins: https://buzz.example.com,tauri://localhost
```

Only include origins that actually need browser or desktop access. Network
setting changes restart Buzz. The outer reverse proxy must pass
`Host: buzz.example.com` unchanged so the request authority matches `RELAY_URL`
and NIP-42 signatures.

### Test The Public Endpoint

Check DNS and the NIP-11 relay document:

```bash
dig +short buzz.example.com
curl -i -H 'Accept: application/nostr+json' https://buzz.example.com/
curl -i https://buzz.example.com/setup/
```

The setup request should be blocked publicly. Then connect with a WebSocket
client:

```bash
websocat wss://buzz.example.com
```

A closed Buzz relay should establish the WebSocket and issue a NIP-42 `AUTH`
challenge. Complete a connection from Buzz desktop using exactly
`wss://buzz.example.com`; repeated authentication failures often indicate that
the client URL, outer `Host`, and configured relay URL differ.

### Cloudflare Limits To Check

- Free and Pro zones currently accept request bodies up to `100 MB`; Business
  accepts `200 MB`, and Enterprise defaults to `500 MB`. This package permits
  git packs up to `500 MB`, so large media or git operations can receive HTTP
  `413` before reaching Buzz. Confirm current values in Cloudflare's
  [upload-limit table](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#upload-limits).
- WebSocket connections can be terminated during edge deploys or after idle
  periods. Clients should reconnect and use ping/pong keepalives.
- WAF and rate-limit rules inspect the initial WebSocket upgrade request. Test
  rules carefully so they do not block native clients.

## What Runs

- `gateway`: NGINX routing `/setup/` to configuration and all other traffic to
  Buzz on Umbrel port `38633`
- `config`: local public-key and canonical-URL setup UI
- `relay`: pinned official `ghcr.io/block/buzz:sha-1a56b7c` image
- `postgres`: PostgreSQL 17
- `redis`: Redis 7 with AOF enabled
- `minio` and `minio-init`: S3-compatible storage and bucket management

Persistent data lives under `~/umbrel/app-data/buzz-relay/data/`:

- `config/`: public owner key, public URL settings, reset state, generated relay
  secrets
- `postgres/`: Buzz database
- `redis/`: Redis AOF data
- `minio/`: media and object storage
- `git/`: persistent git repository storage
- `git-cache/`: persistent git pack cache

PostgreSQL, Redis, and MinIO do not publish host ports. Runtime scripts and the
gateway configuration are checksum-verified from root `*.template` files in a
`pre-start` hook because those are the paths umbrelOS copies during app updates.

## Admin Commands

After the relay has started, the package helper loads the generated relay key
for Buzz's official admin CLI:

```bash
docker exec -it buzz-relay_relay_1 /opt/umbrel-buzz/buzz-admin.sh list-members
docker exec -it buzz-relay_relay_1 /opt/umbrel-buzz/buzz-admin.sh add-member --pubkey <npub-or-hex> --role admin
docker exec -it buzz-relay_relay_1 /opt/umbrel-buzz/buzz-admin.sh remove-member --pubkey <npub-or-hex>
```

The helper uses the generated relay private key. It does not need a user's
Nostr private key.

## Backup And Restore

Umbrel derives `APP_PASSWORD` deterministically from the Umbrel seed. That
password protects PostgreSQL, Redis, and MinIO. A same-seed full-system restore
is therefore the supported low-risk migration path. Copying only this app's
data directory to an Umbrel installation with a different seed is **not**
expected to work unchanged; the restored services still contain credentials
derived from the original seed.

For a coordinated backup:

1. Record the installed app package version and pinned image digest.
2. Stop Buzz Relay in umbrelOS.
3. Back up the complete `~/umbrel/app-data/buzz-relay/` tree while stopped,
   preserving numeric owners, modes, timestamps, links, and extended metadata.
4. Keep PostgreSQL, Redis, MinIO, git, and `data/config/generated.env` from the
   same maintenance window.
5. Start the app and verify NIP-11, NIP-42 login, media access, and git activity.

For restore:

1. Prefer a full Umbrel restore using the same Umbrel seed.
2. Install the same Buzz package/image version first, then stop the app.
3. Restore the complete app tree with ownership and permissions intact. Do not
   blanket-`chown` database directories; each image manages its own ownership.
4. Start the app and verify the setup status, NIP-11 response, NIP-42 client
   login, authenticated media reads, and git data before upgrading.
5. Upgrade only after the restored version is working.

A different-seed host requires a planned database, Redis, and MinIO credential
migration or a logical export/import procedure. This repository does not yet
provide or promise that cross-seed migration.

## Upgrades

The relay image is pinned to a verified upstream commit tag and immutable image
digest. For a manual upgrade, review every upstream `deploy/compose/` file,
update the image tag and digest, regenerate runtime templates, run validation,
then test both a fresh install and a data-preserving upgrade.

After the package has been proven on Umbrel, maintainers can enable the
conservative monitor documented in
[docs/upstream-monitoring.md](docs/upstream-monitoring.md). It opens review pull
requests and never merges, publishes, or applies an upstream update
automatically.

## Security Notes

- The relay uses closed membership mode with NIP-42/NIP-98 authentication.
- Media `GET`/`HEAD` requests require Blossom kind `24242` authorization and
  relay membership. Current official Buzz desktop and CLI clients support this.
  Older or third-party clients may fail with HTTP `401`/`403`; do not disable
  this control without accepting that anyone who learns a media URL can fetch
  it without membership authorization.
- The official relay's default external push delivery URL is explicitly
  disabled. Enabling push delivery later sends delivery metadata to the
  configured external endpoint and requires a separate privacy review.
- Buzz application content is not made end-to-end encrypted by this package.
- The setup UI intentionally has no separate account system. Anyone on the LAN
  who can reach `/setup/` may alter network settings or request a destructive
  reset. Browser requests use a custom same-origin header for CSRF hardening,
  not authentication.
- Public reverse proxies and tunnels must block `/setup` while preserving the
  original `Host` for every relay request.
- The gateway drops all Linux capabilities, then adds only `CHOWN`, `SETGID`,
  and `SETUID` for the official NGINX image's user-switch startup path. The
  gateway and configuration containers also enable `no-new-privileges`.
- Protect the Umbrel host, reverse proxy, database, object storage, git data,
  generated secrets, Umbrel seed, and backups as sensitive infrastructure.

## Validation

Run the local unit/static checks and current official Umbrel linter:

```bash
./scripts/validate.sh
./scripts/run-umbrel-lint.sh
```

Docker and umbrelOS runtime checks are separate and still required. The minimum
release gate is a fresh install plus an upgrade with existing data, initial
setup, relay restart, explicit owner-reset confirmation, backup/restore, NIP-42
authentication, authenticated media access, git operations, and public WSS with
`Host` preservation.

## Upstream References

- [Block Buzz](https://github.com/block/buzz)
- [Buzz production Compose bundle](https://github.com/block/buzz/tree/main/deploy/compose)
- [Umbrel Community App Store template](https://github.com/getumbrel/umbrel-community-app-store)
