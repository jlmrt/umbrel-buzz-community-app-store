#!/usr/bin/env bash

percent_encode_url_component() {
  local input="$1"
  local output=""
  local byte hex index

  local LC_ALL=C
  for ((index = 0; index < ${#input}; index++)); do
    byte="${input:index:1}"
    case "$byte" in
      [a-zA-Z0-9.~_-]) output+="$byte" ;;
      *)
        printf -v hex '%02X' "'$byte"
        output+="%${hex}"
        ;;
    esac
  done
  printf '%s' "$output"
}

validate_service_host() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    printf '[umbrel-buzz] Invalid internal service host in %s.\n' "$name" >&2
    return 1
  fi
}

configure_buzz_service_urls() {
  : "${BUZZ_SERVICE_PASSWORD:?BUZZ_SERVICE_PASSWORD is required}"
  : "${BUZZ_POSTGRES_HOST:?BUZZ_POSTGRES_HOST is required}"
  : "${BUZZ_REDIS_HOST:?BUZZ_REDIS_HOST is required}"

  validate_service_host BUZZ_POSTGRES_HOST "$BUZZ_POSTGRES_HOST" || return 1
  validate_service_host BUZZ_REDIS_HOST "$BUZZ_REDIS_HOST" || return 1

  local encoded_password
  encoded_password="$(percent_encode_url_component "$BUZZ_SERVICE_PASSWORD")"
  export DATABASE_URL="postgres://buzz:${encoded_password}@${BUZZ_POSTGRES_HOST}:5432/buzz"
  export REDIS_URL="redis://:${encoded_password}@${BUZZ_REDIS_HOST}:6379"
  unset BUZZ_SERVICE_PASSWORD encoded_password
}
