#!/bin/sh
set -eu

CONFIG_DIR="${BUZZ_CONFIG_DIR:-/config}"
REQUEST_FILE="${CONFIG_DIR}/reset-request"
RELAY_STOPPED_FILE="${CONFIG_DIR}/reset-relay-stopped"
ACK_DIR="${CONFIG_DIR}/reset-acks"
SERVICE="${BUZZ_RESET_SERVICE:?set BUZZ_RESET_SERVICE}"
CHILD_PID=""

log() {
  printf '[umbrel-buzz-%s] %s\n' "$SERVICE" "$*" >&2
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

service_paths() {
  case "$SERVICE" in
    postgres)
      DATA_DIR=/var/lib/postgresql/data
      ACK_FILE="${ACK_DIR}/postgres-ready"
      ;;
    redis)
      DATA_DIR=/data
      ACK_FILE="${ACK_DIR}/redis-ready"
      ;;
    minio)
      DATA_DIR=/data
      ACK_FILE="${ACK_DIR}/minio-storage-ready"
      ;;
    *)
      log "Unsupported reset service: ${SERVICE}"
      exit 64
      ;;
  esac
}

start_child() {
  case "$SERVICE" in
    postgres)
      /usr/local/bin/docker-entrypoint.sh postgres &
      ;;
    redis)
      /usr/local/bin/docker-entrypoint.sh \
        redis-server --appendonly yes --appendfsync everysec \
        --requirepass "$REDIS_PASSWORD" &
      ;;
    minio)
      minio server /data --console-address ":9001" &
      ;;
  esac
  CHILD_PID=$!
  log "Started process ${CHILD_PID}"
}

stop_child() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    log "Stopping process ${CHILD_PID}"
    kill -TERM "$CHILD_PID"
    wait "$CHILD_PID" || true
  fi
  CHILD_PID=""
}

service_ready() {
  case "$SERVICE" in
    postgres)
      pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
      ;;
    redis)
      redis-cli -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG
      ;;
    minio)
      curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null 2>&1
      ;;
  esac
}

wait_until_ready() {
  attempts=0
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    if service_ready; then
      return 0
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 120 ]; then
      log "Service did not become ready after reset"
      return 1
    fi
    sleep 2
  done
  return 1
}

clear_data() {
  case "$DATA_DIR" in
    /var/lib/postgresql/data|/data) ;;
    *)
      log "Refusing to clear unexpected data directory: ${DATA_DIR}"
      exit 70
      ;;
  esac
  log "Clearing application data in ${DATA_DIR}"
  find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

perform_reset() {
  request_id="$1"
  log "Reset ${request_id} waiting for relay shutdown"
  while [ "$(read_marker "$RELAY_STOPPED_FILE")" != "$request_id" ]; do
    if [ "$(read_marker "$REQUEST_FILE")" != "$request_id" ]; then
      log "Reset request was cancelled before relay shutdown"
      return 0
    fi
    sleep 1
  done

  stop_child
  if ! clear_data; then
    log "Reset ${request_id} could not clear ${DATA_DIR}"
    return 1
  fi
  start_child
  if ! wait_until_ready; then
    stop_child
    return 1
  fi
  write_marker "$ACK_FILE" "$request_id"
  log "Reset ${request_id} complete"
}

shutdown() {
  stop_child
  exit 0
}

trap shutdown INT TERM
service_paths
mkdir -p "$ACK_DIR" "$DATA_DIR"
start_child

while true; do
  if ! kill -0 "$CHILD_PID" 2>/dev/null; then
    wait "$CHILD_PID" || true
    log "Service process exited; restarting"
    sleep 2
    start_child
  fi

  request_id="$(read_marker "$REQUEST_FILE")"
  if [ -n "$request_id" ] && [ "$(read_marker "$ACK_FILE")" != "$request_id" ]; then
    if ! perform_reset "$request_id"; then
      log "Reset ${request_id} failed; retrying"
      sleep 3
      if [ -z "$CHILD_PID" ]; then
        start_child
      fi
    fi
  fi
  sleep 2
done
