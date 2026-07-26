#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1"
test_root="$(mktemp -d)"

cleanup() {
  docker run --rm \
    --mount "type=bind,src=$test_root/package,dst=/package" \
    "$image" \
    chmod -R a+rwX /package >/dev/null 2>&1 || true
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$test_root/package/hooks" "$test_root/package/runtime"
cp -p "$repo_root/buzz-relay/hooks/pre-start" "$test_root/package/hooks/pre-start"
for template in "$repo_root"/buzz-relay/asset-*.template; do
  name="$(basename "${template%.template}")"
  cp "$template" "$test_root/package/$name"
done

run_setup() {
  docker run --rm \
    --mount "type=bind,src=$test_root/package,dst=/package" \
    "$image" \
    sh -euc '
      mkdir -p /package/data/config/reset-acks /package/data/config/backup-acks /package/data/backups /package/data/git /package/data/git-cache /package/data/postgres /package/data/redis /package/data/minio
      if ! APP_DATA_DIR=/package APP_VERSION=test-busybox BUZZ_RUNTIME_IN_PLACE=1 /package/hooks/pre-start; then
        echo >&2 "[umbrel-buzz] ERROR: verified runtime asset staging failed; setup cannot continue. Review the setup container log above."
        exit 1
      fi
    '
}

run_setup >/dev/null
test "$(cat "$test_root/package/runtime/package-version")" = "test-busybox"

# A corrupt source must fail once and return control; Compose must not restart it.
printf 'corrupt\n' >> "$test_root/package/asset-bin-buzz-admin.sh.b64"
if run_setup >/dev/null 2>&1; then
  echo "corrupt runtime asset unexpectedly passed BusyBox verification" >&2
  exit 1
fi

echo "BusyBox setup verification ok"
