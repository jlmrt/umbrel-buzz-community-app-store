#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${BUZZ_CONFIG_DIR:-/config}"
SECRETS_FILE="${CONFIG_DIR}/generated.env"
RUNTIME_FILE="${CONFIG_DIR}/runtime.env"
OWNER_FILE="${CONFIG_DIR}/relay-owner-pubkey"
PENDING_OWNER_FILE="${CONFIG_DIR}/pending-owner-pubkey"
RELAY_URL_FILE="${CONFIG_DIR}/relay-url"
MEDIA_BASE_URL_FILE="${CONFIG_DIR}/media-base-url"
CORS_ORIGINS_FILE="${CONFIG_DIR}/cors-origins"
RESET_REQUEST_FILE="${CONFIG_DIR}/reset-request"
RESET_COMPLETED_FILE="${CONFIG_DIR}/reset-completed"
RESET_ERROR_FILE="${CONFIG_DIR}/reset-error"
RELAY_STOPPED_FILE="${CONFIG_DIR}/reset-relay-stopped"
RESET_ACK_DIR="${CONFIG_DIR}/reset-acks"
RESTART_REQUEST_FILE="${CONFIG_DIR}/restart-request"
RESTART_COMPLETED_FILE="${CONFIG_DIR}/restart-completed"
MINIO_INITIALIZED_FILE="${CONFIG_DIR}/minio-initialized"
STATE_FILE="${CONFIG_DIR}/relay-state"
GIT_DIR="${BUZZ_GIT_REPO_PATH:-/data/git}"
GIT_CACHE_DIR="${BUZZ_GIT_PACK_CACHE_PATH:-/data/git-cache}"
RELAY_PID=""

log() {
  printf '[umbrel-buzz] %s\n' "$*" >&2
}

first_line() {
  local file="$1"
  if [[ -f "$file" ]]; then
    awk 'NF && $1 !~ /^#/ { gsub(/\r/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$file"
  fi
}

write_marker() {
  local destination="$1"
  local value="$2"
  local temporary="${destination}.tmp.$$"
  printf '%s\n' "$value" > "$temporary"
  mv "$temporary" "$destination"
}

write_state() {
  write_marker "$STATE_FILE" "$1"
}

write_shell_var() {
  local name="$1"
  local value="$2"
  printf '%s=%q\n' "$name" "$value"
}

ensure_hex_secret() {
  local name="$1"
  if ! grep -Eq "^${name}=[0-9a-fA-F]{64}$" "$SECRETS_FILE" 2>/dev/null; then
    write_shell_var "$name" "$(openssl rand -hex 32)" >> "$SECRETS_FILE"
  fi
}

ensure_secrets() {
  umask 077
  touch "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  ensure_hex_secret BUZZ_RELAY_PRIVATE_KEY
  ensure_hex_secret BUZZ_GIT_HOOK_HMAC_SECRET
}

derive_media_base_url() {
  local relay_url="$1"
  case "$relay_url" in
    wss://*) printf 'https://%s/media\n' "${relay_url#wss://}" ;;
    ws://*) printf 'http://%s/media\n' "${relay_url#ws://}" ;;
    *) printf 'http://localhost:3000/media\n' ;;
  esac
}

derive_cors_origin() {
  local relay_url="$1"
  case "$relay_url" in
    wss://*) printf 'https://%s\n' "${relay_url#wss://}" ;;
    ws://*) printf 'http://%s\n' "${relay_url#ws://}" ;;
    *) printf 'http://localhost:3000\n' ;;
  esac
}

load_owner() {
  local owner_pubkey="${RELAY_OWNER_PUBKEY:-}"
  if [[ -z "$owner_pubkey" ]]; then
    owner_pubkey="$(first_line "$OWNER_FILE")"
  fi
  owner_pubkey="$(printf '%s' "$owner_pubkey" | tr 'A-F' 'a-f')"
  if [[ "$owner_pubkey" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' "$owner_pubkey"
    return 0
  fi
  return 1
}

write_runtime() {
  local owner_pubkey="$1"
  local relay_url="$2"
  local media_base_url cors_origins

  media_base_url="${BUZZ_MEDIA_BASE_URL:-$(first_line "$MEDIA_BASE_URL_FILE")}"
  media_base_url="${media_base_url:-$(derive_media_base_url "$relay_url")}"
  cors_origins="${BUZZ_CORS_ORIGINS:-$(first_line "$CORS_ORIGINS_FILE")}"
  cors_origins="${cors_origins:-$(derive_cors_origin "$relay_url")}"

  {
    write_shell_var RELAY_URL "$relay_url"
    write_shell_var BUZZ_MEDIA_BASE_URL "$media_base_url"
    write_shell_var BUZZ_CORS_ORIGINS "$cors_origins"
    write_shell_var RELAY_OWNER_PUBKEY "$owner_pubkey"
  } > "${RUNTIME_FILE}.tmp"
  mv "${RUNTIME_FILE}.tmp" "$RUNTIME_FILE"
  chmod 600 "$RUNTIME_FILE"
}

load_relay_url() {
  local relay_url
  relay_url="${RELAY_URL:-$(first_line "$RELAY_URL_FILE")}"
  if [[ -z "$relay_url" ]]; then
    return 1
  fi
  if [[ ! "$relay_url" =~ ^wss?://[^/[:space:]]+/?$ ]]; then
    log "Invalid relay URL '${relay_url}'. Use a root ws:// or wss:// URL."
    return 1
  fi
  printf '%s\n' "${relay_url%/}"
}

start_relay() {
  local owner_pubkey="$1"
  local relay_url="$2"
  ensure_secrets
  write_runtime "$owner_pubkey" "$relay_url"
  set -a
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
  # shellcheck disable=SC1090
  . "$RUNTIME_FILE"
  set +a
  write_state starting
  log "Starting Buzz relay for ${RELAY_URL}"
  /usr/local/bin/buzz-relay &
  RELAY_PID=$!
}

stop_relay() {
  if [[ -n "$RELAY_PID" ]] && kill -0 "$RELAY_PID" 2>/dev/null; then
    write_state stopping
    log "Stopping Buzz relay"
    kill -TERM "$RELAY_PID"
    wait "$RELAY_PID" || true
  fi
  RELAY_PID=""
}

clear_directory() {
  local directory="$1"
  case "$directory" in
    /data/git|/data/git-cache) ;;
    *)
      log "Refusing to clear unexpected directory: ${directory}"
      return 1
      ;;
  esac
  find "$directory" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

wait_for_reset_ack() {
  local request_id="$1"
  local name="$2"
  local path="${RESET_ACK_DIR}/${name}-ready"
  while [[ "$(first_line "$path")" != "$request_id" ]]; do
    if [[ "$(first_line "$RESET_REQUEST_FILE")" != "$request_id" ]]; then
      return 1
    fi
    sleep 1
  done
}

perform_reset() {
  local request_id="$1"
  local pending_owner
  pending_owner="$(first_line "$PENDING_OWNER_FILE")"
  pending_owner="$(printf '%s' "$pending_owner" | tr 'A-F' 'a-f')"
  if [[ ! "$pending_owner" =~ ^[0-9a-f]{64}$ ]]; then
    write_marker "$RESET_ERROR_FILE" "Reset rejected because the pending owner public key is invalid."
    rm -f "$RESET_REQUEST_FILE" "$PENDING_OWNER_FILE"
    return 1
  fi

  stop_relay
  write_state resetting
  write_marker "$RELAY_STOPPED_FILE" "$request_id"
  log "Waiting for database, cache, and object storage reset ${request_id}"
  if ! wait_for_reset_ack "$request_id" postgres ||
     ! wait_for_reset_ack "$request_id" redis ||
     ! wait_for_reset_ack "$request_id" minio; then
    write_marker "$RESET_ERROR_FILE" "Reset coordination was interrupted before storage services were ready."
    return 1
  fi

  if ! clear_directory "$GIT_DIR" || ! clear_directory "$GIT_CACHE_DIR"; then
    write_marker "$RESET_ERROR_FILE" "Reset stopped because repository storage could not be cleared."
    return 1
  fi
  rm -f "$SECRETS_FILE" "$RUNTIME_FILE"
  if ! mv "$PENDING_OWNER_FILE" "$OWNER_FILE"; then
    write_marker "$RESET_ERROR_FILE" "Reset stopped because the pending owner key could not be promoted."
    return 1
  fi
  chmod 600 "$OWNER_FILE"
  write_marker "$RESET_COMPLETED_FILE" "$request_id"
  rm -f "$RESET_REQUEST_FILE" "$RESET_ERROR_FILE" "$RELAY_STOPPED_FILE"
  log "Full application data reset ${request_id} complete"
}

shutdown() {
  stop_relay
  exit 0
}

trap shutdown INT TERM
mkdir -p "$CONFIG_DIR" "$RESET_ACK_DIR" "$GIT_DIR" "$GIT_CACHE_DIR"
umask 077

while true; do
  reset_id="$(first_line "$RESET_REQUEST_FILE")"
  if [[ -n "$reset_id" && "$(first_line "$RESET_COMPLETED_FILE")" != "$reset_id" ]]; then
    perform_reset "$reset_id" || true
    sleep 1
    continue
  fi

  restart_id="$(first_line "$RESTART_REQUEST_FILE")"
  if [[ -n "$restart_id" ]]; then
    write_marker "$RESTART_COMPLETED_FILE" "$restart_id"
    rm -f "$RESTART_REQUEST_FILE"
  fi

  if ! owner_pubkey="$(load_owner)"; then
    write_state waiting-for-configuration
    sleep 2
    continue
  fi

  if ! relay_url="$(load_relay_url)"; then
    write_state waiting-for-canonical-url
    sleep 2
    continue
  fi

  if [[ "$(first_line "$MINIO_INITIALIZED_FILE")" != ready ]]; then
    write_state waiting-for-storage
    sleep 2
    continue
  fi

  start_relay "$owner_pubkey" "$relay_url"
  action=""
  while kill -0 "$RELAY_PID" 2>/dev/null; do
    reset_id="$(first_line "$RESET_REQUEST_FILE")"
    restart_id="$(first_line "$RESTART_REQUEST_FILE")"
    if [[ -n "$reset_id" ]]; then
      action=reset
      break
    fi
    if [[ -n "$restart_id" ]]; then
      action=restart
      break
    fi
    sleep 2
  done

  if [[ "$action" == reset ]]; then
    perform_reset "$reset_id" || true
    continue
  fi
  if [[ "$action" == restart ]]; then
    stop_relay
    write_marker "$RESTART_COMPLETED_FILE" "$restart_id"
    rm -f "$RESTART_REQUEST_FILE"
    log "Network settings applied; restarting relay"
    continue
  fi

  wait "$RELAY_PID" || true
  RELAY_PID=""
  write_state stopped
  log "Relay process exited; retrying"
  sleep 3
done
