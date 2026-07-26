#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../buzz-relay/assets-src/bin/service-urls.sh
source "${repo_root}/buzz-relay/assets-src/bin/service-urls.sh"

BUZZ_SERVICE_PASSWORD="aZ09-._~:/?#[]@!\$&'()*+,;=% space"
BUZZ_POSTGRES_HOST="buzz-relay_postgres_1"
BUZZ_REDIS_HOST="buzz-relay_redis_1"
configure_buzz_service_urls

encoded="aZ09-._~%3A%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D%25%20space"
expected_database_url="postgres://buzz:${encoded}@buzz-relay_postgres_1:5432/buzz"
expected_redis_url="redis://:${encoded}@buzz-relay_redis_1:6379"

[[ "$DATABASE_URL" == "$expected_database_url" ]]
[[ "$REDIS_URL" == "$expected_redis_url" ]]
[[ -z "${BUZZ_SERVICE_PASSWORD+x}" ]]

if (
  BUZZ_SERVICE_PASSWORD=test
  BUZZ_POSTGRES_HOST='postgres/other-app'
  BUZZ_REDIS_HOST=buzz-relay_redis_1
  configure_buzz_service_urls
) 2>/dev/null; then
  printf 'unsafe internal service host was accepted\n' >&2
  exit 1
fi

printf 'service URL credential encoding ok\n'
