#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
worker_pid=""

cleanup() {
  if [[ -n "$worker_pid" ]]; then
    kill -TERM "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT

mkdir -p \
  "$temporary/config/backup-acks" \
  "$temporary/backups" \
  "$temporary/source/postgres" \
  "$temporary/source/redis" \
  "$temporary/source/minio" \
  "$temporary/source/git" \
  "$temporary/source/git-cache" \
  "$temporary/fake-bin"

request_id="12345678-1234-1234-1234-123456789abc"
printf '%s\n' "$request_id" > "$temporary/config/backup-request"
printf '%s\n' "$request_id" > "$temporary/config/backup-acks/relay-stopped"
printf '%s\n' "$request_id" > "$temporary/config/backup-acks/minio-stopped"
printf '%s\n' '11' > "$temporary/source/git/repository.pack"
printf '%s\n' '22' > "$temporary/source/minio/object.bin"
printf '%s\n' 'must-not-be-archived' > "$temporary/source/redis/cache.aof"
printf '%s\n' 'relay-secret' > "$temporary/config/generated.env"
printf '%s\n' 'wss://community.example.com' > "$temporary/config/relay-url"

cat > "$temporary/fake-bin/psql" <<'EOF'
#!/bin/sh
printf '128\n'
EOF

cat > "$temporary/fake-bin/pg_dump" <<'EOF'
#!/bin/sh
output=''
for argument in "$@"; do
  case "$argument" in
    --file=*) output="${argument#--file=}" ;;
  esac
done
test -n "$output"
printf 'logical-postgres-dump\n' > "$output"
EOF
chmod +x "$temporary/fake-bin/psql" "$temporary/fake-bin/pg_dump"

env \
  PATH="$temporary/fake-bin:$PATH" \
  BUZZ_CONFIG_DIR="$temporary/config" \
  BUZZ_BACKUP_DIR="$temporary/backups" \
  BUZZ_BACKUP_SOURCE_ROOT="$temporary/source" \
  BUZZ_BACKUP_MAX_BYTES="1073741824" \
  BUZZ_PACKAGE_VERSION="test-1" \
  BUZZ_POSTGRES_HOST="buzz-relay_postgres_1" \
  POSTGRES_DB="buzz" \
  POSTGRES_USER="buzz" \
  POSTGRES_PASSWORD="arbitrary password:/?#[]@" \
  "$repo_root/buzz-relay/assets-src/bin/operations-entrypoint.sh" \
  >"$temporary/worker.log" 2>&1 &
worker_pid=$!

for _ in {1..100}; do
  state="$(sed -n '1p' "$temporary/config/backup-state" 2>/dev/null || true)"
  if [[ "$state" == completed || "$state" == error ]]; then
    break
  fi
  sleep 0.1
done

[[ "$(sed -n '1p' "$temporary/config/backup-state")" == completed ]]
[[ ! -e "$temporary/config/backup-request" ]]
archive_name="$(sed -n '1p' "$temporary/config/backup-latest-name")"
[[ "$archive_name" =~ ^buzz-relay-backup-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\.tar$ ]]
archive="$temporary/backups/$archive_name"
[[ -f "$archive" && ! -L "$archive" ]]

mkdir -p "$temporary/extracted"
tar -xf "$archive" -C "$temporary/extracted"
(
  cd "$temporary/extracted"
  sha256sum --check SHA256SUMS >/dev/null
)

expected=(
  SHA256SUMS
  config.tar.gz
  git.tar.gz
  manifest.json
  minio.tar.gz
  postgres.dump
)
mapfile -t actual < <(find "$temporary/extracted" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | sort)
[[ "${actual[*]}" == "${expected[*]}" ]]
tar -tzf "$temporary/extracted/config.tar.gz" | grep -qx './generated.env'
tar -tzf "$temporary/extracted/git.tar.gz" | grep -qx './repository.pack'
tar -tzf "$temporary/extracted/minio.tar.gz" | grep -qx './object.bin'
! tar -tf "$archive" | grep -Eq 'redis|git-cache'
grep -q '"excluded_rebuildable_state": \["redis", "git-cache"\]' "$temporary/extracted/manifest.json"

printf 'backup worker archive and checksum validation ok\n'
