#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${BUZZ_CONFIG_DIR:-/config}"
SECRETS_FILE="${CONFIG_DIR}/generated.env"
RUNTIME_FILE="${CONFIG_DIR}/runtime.env"
OWNER_FILE="${CONFIG_DIR}/relay-owner-pubkey"
RELAY_URL_FILE="${CONFIG_DIR}/relay-url"
MEDIA_BASE_URL_FILE="${CONFIG_DIR}/media-base-url"
CORS_ORIGINS_FILE="${CONFIG_DIR}/cors-origins"

log() {
  printf '[umbrel-buzz] %s\n' "$*" >&2
}

first_line() {
  local file="$1"
  awk 'NF && $1 !~ /^#/ { gsub(/\r/, ""); print; exit }' "$file"
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

derive_media_base_url() {
  local relay_url="$1"
  case "$relay_url" in
    wss://*) printf 'https://%s/media\n' "${relay_url#wss://}" ;;
    ws://*) printf 'http://%s/media\n' "${relay_url#ws://}" ;;
    https://*) printf '%s/media\n' "$relay_url" ;;
    http://*) printf '%s/media\n' "$relay_url" ;;
    *) printf 'http://localhost:3000/media\n' ;;
  esac
}

derive_cors_origin() {
  local relay_url="$1"
  case "$relay_url" in
    wss://*) printf 'https://%s\n' "${relay_url#wss://}" ;;
    ws://*) printf 'http://%s\n' "${relay_url#ws://}" ;;
    https://*|http://*) printf '%s\n' "$relay_url" ;;
    *) printf 'http://localhost:3000\n' ;;
  esac
}

mkdir -p "$CONFIG_DIR"
umask 077
touch "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

ensure_hex_secret BUZZ_RELAY_PRIVATE_KEY
ensure_hex_secret BUZZ_GIT_HOOK_HMAC_SECRET

set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a

if [[ ! "${BUZZ_RELAY_PRIVATE_KEY:-}" =~ ^[0-9a-fA-F]{64}$ ]]; then
  log "generated.env has an invalid BUZZ_RELAY_PRIVATE_KEY; fix or remove ${SECRETS_FILE}"
  exit 78
fi

if [[ "${#BUZZ_GIT_HOOK_HMAC_SECRET:-}" -lt 32 ]]; then
  log "generated.env has an invalid BUZZ_GIT_HOOK_HMAC_SECRET; fix or remove ${SECRETS_FILE}"
  exit 78
fi

owner_pubkey="${RELAY_OWNER_PUBKEY:-}"
if [[ -z "$owner_pubkey" && -f "$OWNER_FILE" ]]; then
  owner_pubkey="$(first_line "$OWNER_FILE" | tr 'A-F' 'a-f' | tr -d '[:space:]')"
fi

if [[ ! "$owner_pubkey" =~ ^[0-9a-f]{64}$ ]]; then
  log "Buzz is waiting for the relay owner public key."
  log "Create ${OWNER_FILE} containing the 64-character hex public key for the Nostr account that should own this relay."
  log "Do not put a Nostr private key or nsec in this file."
  exit 78
fi
export RELAY_OWNER_PUBKEY="$owner_pubkey"

relay_url="${RELAY_URL:-}"
if [[ -z "$relay_url" && -f "$RELAY_URL_FILE" ]]; then
  relay_url="$(first_line "$RELAY_URL_FILE" | tr -d '[:space:]')"
fi
if [[ -z "$relay_url" && -n "${UMBREL_APP_DOMAIN:-}" && -n "${UMBREL_APP_PORT:-}" ]]; then
  relay_url="ws://${UMBREL_APP_DOMAIN}:${UMBREL_APP_PORT}"
fi
relay_url="${relay_url:-ws://localhost:3000}"

if [[ ! "$relay_url" =~ ^wss?://[^/[:space:]]+.*$ ]]; then
  log "Invalid relay URL '${relay_url}'. Use ws://host:port for local-only or wss://buzz.example.com for production."
  exit 78
fi
export RELAY_URL="$relay_url"

media_base_url="${BUZZ_MEDIA_BASE_URL:-}"
if [[ -z "$media_base_url" && -f "$MEDIA_BASE_URL_FILE" ]]; then
  media_base_url="$(first_line "$MEDIA_BASE_URL_FILE" | tr -d '[:space:]')"
fi
media_base_url="${media_base_url:-$(derive_media_base_url "$relay_url")}"
export BUZZ_MEDIA_BASE_URL="$media_base_url"

cors_origins="${BUZZ_CORS_ORIGINS:-}"
if [[ -z "$cors_origins" && -f "$CORS_ORIGINS_FILE" ]]; then
  cors_origins="$(first_line "$CORS_ORIGINS_FILE" | tr -d '[:space:]')"
fi
cors_origins="${cors_origins:-$(derive_cors_origin "$relay_url")}"
export BUZZ_CORS_ORIGINS="$cors_origins"

{
  write_shell_var RELAY_URL "$RELAY_URL"
  write_shell_var BUZZ_MEDIA_BASE_URL "$BUZZ_MEDIA_BASE_URL"
  write_shell_var BUZZ_CORS_ORIGINS "$BUZZ_CORS_ORIGINS"
  write_shell_var RELAY_OWNER_PUBKEY "$RELAY_OWNER_PUBKEY"
} > "${RUNTIME_FILE}.tmp"
mv "${RUNTIME_FILE}.tmp" "$RUNTIME_FILE"
chmod 600 "$RUNTIME_FILE"

log "Starting Buzz relay for ${RELAY_URL}"
exec /usr/local/bin/buzz-relay
