#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${BUZZ_CONFIG_DIR:-/config}"

for file in "${CONFIG_DIR}/generated.env" "${CONFIG_DIR}/runtime.env"; do
  if [[ -f "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a
  fi
done

if [[ -z "${BUZZ_RELAY_PRIVATE_KEY:-}" ]]; then
  printf 'Missing %s/generated.env. Start the relay once so Umbrel can generate relay secrets.\n' "$CONFIG_DIR" >&2
  exit 78
fi

exec /usr/local/bin/buzz-admin "$@"
