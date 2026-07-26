#!/bin/sh
set -eu

CONFIG_DIR="${BUZZ_CONFIG_DIR:-/config}"
BACKUP_DIR="${BUZZ_BACKUP_DIR:-/backups}"
SOURCE_ROOT="${BUZZ_BACKUP_SOURCE_ROOT:-/source}"
REQUEST_FILE="${CONFIG_DIR}/backup-request"
STATE_FILE="${CONFIG_DIR}/backup-state"
PROGRESS_FILE="${CONFIG_DIR}/backup-progress"
MESSAGE_FILE="${CONFIG_DIR}/backup-message"
CURRENT_ID_FILE="${CONFIG_DIR}/backup-current-id"
LATEST_NAME_FILE="${CONFIG_DIR}/backup-latest-name"
LATEST_SIZE_FILE="${CONFIG_DIR}/backup-latest-size"
LATEST_SHA_FILE="${CONFIG_DIR}/backup-latest-sha256"
LATEST_CREATED_FILE="${CONFIG_DIR}/backup-latest-created-at"
HEARTBEAT_FILE="${CONFIG_DIR}/operations-heartbeat"
STORAGE_FILE="${CONFIG_DIR}/storage-stats"
ACK_DIR="${CONFIG_DIR}/backup-acks"
MAX_BYTES="${BUZZ_BACKUP_MAX_BYTES:-53687091200}"
PACKAGE_VERSION="${BUZZ_PACKAGE_VERSION:-unknown}"
POSTGRES_HOST="${BUZZ_POSTGRES_HOST:-buzz-relay_postgres_1}"
POSTGRES_DB="${POSTGRES_DB:-buzz}"
POSTGRES_USER="${POSTGRES_USER:-buzz}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

umask 077

log() {
  printf '[umbrel-buzz-operations] %s\n' "$*" >&2
}

read_marker() {
  if [ -f "$1" ]; then
    sed -n '/[^[:space:]]/ { s/[[:space:]]//g; p; q; }' "$1"
  fi
}

write_marker() {
  destination="$1"
  value="$2"
  temporary="${destination}.tmp.$$"
  printf '%s\n' "$value" > "$temporary"
  mv "$temporary" "$destination"
  chmod 0644 "$destination"
}

write_state() {
  write_marker "$STATE_FILE" "$1"
  write_marker "$PROGRESS_FILE" "$2"
  write_marker "$MESSAGE_FILE" "$3"
}

valid_request_id() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

directory_kib() {
  if [ -d "$1" ]; then
    du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 + 0 }'
  else
    printf '0\n'
  fi
}

write_storage_stats() {
  temporary="${STORAGE_FILE}.tmp.$$"
  {
    printf 'measured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'config_kib=%s\n' "$(directory_kib "$CONFIG_DIR")"
    printf 'postgres_kib=%s\n' "$(directory_kib "${SOURCE_ROOT}/postgres")"
    printf 'redis_kib=%s\n' "$(directory_kib "${SOURCE_ROOT}/redis")"
    printf 'minio_kib=%s\n' "$(directory_kib "${SOURCE_ROOT}/minio")"
    printf 'git_kib=%s\n' "$(directory_kib "${SOURCE_ROOT}/git")"
    printf 'git_cache_kib=%s\n' "$(directory_kib "${SOURCE_ROOT}/git-cache")"
    printf 'backups_kib=%s\n' "$(directory_kib "$BACKUP_DIR")"
  } > "$temporary"
  mv "$temporary" "$STORAGE_FILE"
  chmod 0644 "$STORAGE_FILE"
}

heartbeat_loop() {
  while true; do
    write_marker "$HEARTBEAT_FILE" "$(date +%s)"
    sleep 5
  done
}

storage_loop() {
  while true; do
    write_storage_stats || true
    sleep 60
  done
}

wait_for_ack() {
  request_id="$1"
  service="$2"
  ack_file="${ACK_DIR}/${service}-stopped"
  attempts=0
  while [ "$(read_marker "$ack_file")" != "$request_id" ]; do
    if [ "$(read_marker "$REQUEST_FILE")" != "$request_id" ]; then
      return 1
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 120 ]; then
      return 1
    fi
    sleep 1
  done
}

database_size_kib() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -Atqc "SELECT pg_database_size(current_database()) / 1024" 2>/dev/null
}

copy_backup_config() {
  destination="$1"
  mkdir -p "$destination"
  for name in \
    relay-owner-pubkey \
    relay-url \
    media-base-url \
    cors-origins \
    community-mode \
    generated.env
  do
    if [ -f "${CONFIG_DIR}/${name}" ]; then
      cp "${CONFIG_DIR}/${name}" "${destination}/${name}"
      chmod 600 "${destination}/${name}"
    fi
  done
}

fail_backup() {
  message="$1"
  log "$message"
  write_state error 0 "$message"
  rm -f "$REQUEST_FILE"
}

perform_backup() {
  request_id="$1"
  stage="${BACKUP_DIR}/.stage-${request_id}"
  partial="${BACKUP_DIR}/.partial-${request_id}.tar"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  short_id="$(printf '%s' "$request_id" | cut -c1-8)"
  archive_name="buzz-relay-backup-${timestamp}-${short_id}.tar"
  archive_path="${BACKUP_DIR}/${archive_name}"

  rm -rf "$stage"
  rm -f "$partial"
  mkdir -p "$stage/config"
  write_marker "$CURRENT_ID_FILE" "$request_id"
  write_state pausing 5 "Pausing relay writes"

  if ! wait_for_ack "$request_id" relay || ! wait_for_ack "$request_id" minio; then
    rm -rf "$stage"
    fail_backup "Could not pause relay and object storage safely"
    return 1
  fi

  write_state preparing 15 "Checking backup size and free space"
  database_kib="$(database_size_kib || printf '0')"
  case "$database_kib" in
    ''|*[!0-9]*)
      rm -rf "$stage"
      fail_backup "Could not measure the PostgreSQL database safely"
      return 1
      ;;
  esac
  source_kib=$((
    $(directory_kib "${SOURCE_ROOT}/git") +
    $(directory_kib "${SOURCE_ROOT}/minio") +
    $(directory_kib "$CONFIG_DIR") +
    database_kib
  ))
  case "$MAX_BYTES" in
    ''|*[!0-9]*)
      rm -rf "$stage"
      fail_backup "Configured backup size limit is invalid"
      return 1
      ;;
  esac
  max_kib=$((MAX_BYTES / 1024))
  available_kib="$(df -Pk "$BACKUP_DIR" | awk 'NR == 2 { print $4 + 0 }')"
  case "$available_kib" in
    ''|*[!0-9]*)
      rm -rf "$stage"
      fail_backup "Could not measure free backup storage"
      return 1
      ;;
  esac
  required_kib=$((source_kib * 2 + 524288))
  if [ "$source_kib" -gt "$max_kib" ]; then
    rm -rf "$stage"
    fail_backup "Backup source exceeds the configured export limit"
    return 1
  fi
  if [ "$available_kib" -lt "$required_kib" ]; then
    rm -rf "$stage"
    fail_backup "Not enough free space to build the backup archive safely"
    return 1
  fi

  write_state dumping-database 25 "Creating a consistent PostgreSQL dump"
  if ! PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
    -h "$POSTGRES_HOST" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    --format=custom \
    --file="${stage}/postgres.dump"
  then
    rm -rf "$stage"
    fail_backup "PostgreSQL backup failed"
    return 1
  fi

  write_state archiving 45 "Archiving configuration and relay identity"
  copy_backup_config "${stage}/config"
  if ! tar -czf "${stage}/config.tar.gz" -C "${stage}/config" .; then
    rm -rf "$stage"
    fail_backup "Configuration archive failed"
    return 1
  fi
  rm -rf "${stage}/config"

  write_state archiving 60 "Archiving git repositories"
  if ! tar -czf "${stage}/git.tar.gz" -C "${SOURCE_ROOT}/git" .; then
    rm -rf "$stage"
    fail_backup "Git repository archive failed"
    return 1
  fi

  write_state archiving 75 "Archiving object storage"
  if ! tar -czf "${stage}/minio.tar.gz" -C "${SOURCE_ROOT}/minio" .; then
    rm -rf "$stage"
    fail_backup "Object storage archive failed"
    return 1
  fi

  case "$PACKAGE_VERSION" in
    *[!A-Za-z0-9._-]*) package_version=unknown ;;
    *) package_version="$PACKAGE_VERSION" ;;
  esac
  cat > "${stage}/manifest.json" <<EOF
{
  "format_version": 1,
  "app_id": "buzz-relay",
  "package_version": "${package_version}",
  "created_at": "${created_at}",
  "components": ["postgres.dump", "config.tar.gz", "git.tar.gz", "minio.tar.gz"],
  "excluded_rebuildable_state": ["redis", "git-cache"]
}
EOF
  (
    cd "$stage"
    sha256sum manifest.json postgres.dump config.tar.gz git.tar.gz minio.tar.gz > SHA256SUMS
  )

  write_state finalizing 90 "Finalizing and checksumming archive"
  if ! tar -cf "$partial" \
    -C "$stage" \
    manifest.json SHA256SUMS postgres.dump config.tar.gz git.tar.gz minio.tar.gz
  then
    rm -rf "$stage"
    rm -f "$partial"
    fail_backup "Final backup archive failed"
    return 1
  fi
  mv "$partial" "$archive_path"
  chmod 600 "$archive_path"
  chown 1000:1000 "$archive_path" 2>/dev/null || true

  archive_size="$(wc -c < "$archive_path" | tr -d '[:space:]')"
  archive_sha="$(sha256sum "$archive_path" | awk '{ print $1 }')"
  write_marker "$LATEST_NAME_FILE" "$archive_name"
  write_marker "$LATEST_SIZE_FILE" "$archive_size"
  write_marker "$LATEST_SHA_FILE" "$archive_sha"
  write_marker "$LATEST_CREATED_FILE" "$created_at"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'buzz-relay-backup-*.tar' ! -name "$archive_name" -delete
  rm -rf "$stage"
  rm -f "$REQUEST_FILE"
  write_state completed 100 "Backup ready to download"
  write_storage_stats || true
  log "Backup ${archive_name} completed"
}

shutdown() {
  kill "$HEARTBEAT_PID" "$STORAGE_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" "$STORAGE_PID" 2>/dev/null || true
  exit 0
}

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$ACK_DIR" \
  "${SOURCE_ROOT}/git" "${SOURCE_ROOT}/minio"
heartbeat_loop &
HEARTBEAT_PID=$!
storage_loop &
STORAGE_PID=$!
trap shutdown INT TERM

while true; do
  request_id="$(read_marker "$REQUEST_FILE")"
  if [ -n "$request_id" ]; then
    if valid_request_id "$request_id"; then
      perform_backup "$request_id" || true
    else
      fail_backup "Backup request identifier is invalid"
    fi
  fi
  sleep 2
done
