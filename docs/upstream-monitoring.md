# Buzz Upstream Monitoring

The repository includes a conservative GitHub Actions workflow at
`.github/workflows/check-buzz-upstream.yml`.

It is designed for the second milestone, after a fresh Umbrel install and an
upgrade have been proven running. The first milestone remains getting the app
package working with a stable owner public key, persistent storage, and HTTPS/WSS
access.

## What The Workflow Does

- Checks Block's official `block/buzz` repository.
- Verifies the matching official GHCR image tag is pullable.
- Updates the pinned Buzz image tag/digest in `buzz-relay/docker-compose.yml`.
- Updates the Umbrel app version and release notes.
- Enumerates and records hashes for every file under upstream
  `deploy/compose/`, including newly added files.
- Opens a pull request for human review.
- Fails visibly if the expected official image, deployment directory, or core
  production files are missing.

It does not merge, tag, release, deploy, or publish updates automatically.
All third-party GitHub Actions are pinned to full commit SHAs. The workflow has
only `contents: write` and `pull-requests: write` permissions, used to create its
review branch and pull request.

## Enable Scheduled Checks

Scheduled runs are disabled by default. To enable them after the app has been
proven running:

1. In GitHub, open the repository settings.
2. Go to **Secrets and variables** -> **Actions** -> **Variables**.
3. Add `ENABLE_BUZZ_UPSTREAM_MONITOR` with value `true`.
4. Optionally add `BUZZ_UPSTREAM_STRATEGY`.

Supported strategies:

- `default-branch` (default): follows the upstream default branch and pins the
  package to the matching `ghcr.io/block/buzz:sha-<commit>` image. This matches
  Buzz's current production Compose guidance while the project is early.
- `latest-release`: follows the latest GitHub release tag, if that tag has a
  matching pullable `sha-<commit>` container image.

You can also run the workflow manually with **Run workflow**.

The scheduled event remains present but its job is skipped unless
`ENABLE_BUZZ_UPSTREAM_MONITOR` is exactly `true`. Keep it disabled until the
runtime release gate in the main README has passed.

## Review Checklist

Before merging any generated PR:

- Read the upstream Buzz release notes and production `deploy/compose/` changes.
- Confirm no new required environment variables, services, ports, or volumes
  were added upstream.
- Confirm every added, removed, or changed `deploy/compose/` file is understood.
- Confirm the generated package still disables external push delivery and
  requires authenticated media reads, unless a reviewed compatibility decision
  explicitly changes those defaults.
- Test a fresh Umbrel install.
- Test an upgrade using existing `~/umbrel/app-data/buzz-relay/data/`.
- Confirm `config/generated.env` was preserved and not regenerated.
- Confirm the public relay URL still resolves over HTTPS/WSS.
- Run the generated-asset check and official pinned Umbrel linter.

Do not enable auto-merge for upstream monitor PRs. Buzz is a relay with
persistent database, object-storage, git, and identity state; updates must be
reviewed and tested deliberately.
