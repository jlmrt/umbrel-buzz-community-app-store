#!/bin/sh
set -eu

CONFIG_DIR="${BUZZ_CONFIG_DIR:-/config}"
: "${BUZZ_S3_ENDPOINT:?BUZZ_S3_ENDPOINT is required}"
REQUEST_FILE="${CONFIG_DIR}/reset-request"
ACK_DIR="${CONFIG_DIR}/reset-acks"
STORAGE_READY_FILE="${ACK_DIR}/minio-storage-ready"
MINIO_READY_FILE="${ACK_DIR}/minio-ready"
INITIALIZED_FILE="${CONFIG_DIR}/minio-initialized"

log() {
  printf '[umbrel-buzz-minio-init] %s\n' "$*" >&2
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
}

ensure_bucket() {
  until mc alias set local "$BUZZ_S3_ENDPOINT" "$BUZZ_S3_ACCESS_KEY" "$BUZZ_S3_SECRET_KEY" >/dev/null 2>&1; do
    sleep 2
  done
  mc mb --ignore-existing "local/${BUZZ_S3_BUCKET}" >/dev/null
  mc anonymous set none "local/${BUZZ_S3_BUCKET}" >/dev/null
}

mkdir -p "$ACK_DIR"
ensure_bucket
write_marker "$INITIALIZED_FILE" ready
log "Media bucket ready"

while true; do
  request_id="$(read_marker "$REQUEST_FILE")"
  if [ -n "$request_id" ] && [ "$(read_marker "$MINIO_READY_FILE")" != "$request_id" ]; then
    while [ "$(read_marker "$STORAGE_READY_FILE")" != "$request_id" ]; do
      if [ "$(read_marker "$REQUEST_FILE")" != "$request_id" ]; then
        request_id=""
        break
      fi
      sleep 1
    done
    if [ -n "$request_id" ]; then
      ensure_bucket
      write_marker "$MINIO_READY_FILE" "$request_id"
      log "Media bucket reset ${request_id} complete"
    fi
  fi
  sleep 2
done
