#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ruby -e 'require "yaml"; %w[umbrel-app-store.yml buzz-relay/umbrel-app.yml buzz-relay/docker-compose.yml .github/workflows/check-buzz-upstream.yml .github/workflows/validate.yml].each { |path| YAML.load_file(path); puts "yaml ok: #{path}" }'
python3 -m json.tool .github/upstream-buzz.json >/dev/null
echo "json ok: .github/upstream-buzz.json"

bash -n buzz-relay/assets-src/bin/relay-entrypoint.sh
bash -n buzz-relay/assets-src/bin/buzz-admin.sh
bash -n buzz-relay/assets-src/bin/resettable-service-entrypoint.sh
bash -n buzz-relay/assets-src/bin/minio-init-entrypoint.sh
bash -n buzz-relay/assets-src/bin/service-urls.sh
bash -n buzz-relay/exports.sh
bash -n buzz-relay/hooks/pre-start
bash -n scripts/validate.sh
bash -n scripts/run-umbrel-lint.sh
bash -n tests/test_service_urls.sh

python3 -m py_compile scripts/check_upstream_buzz.py
python3 -m py_compile scripts/generate_runtime_assets.py
python3 -m py_compile buzz-relay/assets-src/config-ui/server.py
python3 scripts/generate_runtime_assets.py --check
python3 -m unittest discover -s tests -v
tests/test_service_urls.sh

runtime_test="$(mktemp -d)"
trap 'rm -rf "$runtime_test"' EXIT
cp buzz-relay/asset-*.template "$runtime_test/"
for template in "$runtime_test"/*.template; do
  cp "$template" "${template%.template}"
done
APP_DATA_DIR="$runtime_test" buzz-relay/hooks/pre-start >/dev/null
cmp buzz-relay/assets-src/bin/buzz-admin.sh "$runtime_test/runtime/bin/buzz-admin.sh"
cmp buzz-relay/assets-src/bin/minio-init-entrypoint.sh "$runtime_test/runtime/bin/minio-init-entrypoint.sh"
cmp buzz-relay/assets-src/bin/relay-entrypoint.sh "$runtime_test/runtime/bin/relay-entrypoint.sh"
cmp buzz-relay/assets-src/bin/resettable-service-entrypoint.sh "$runtime_test/runtime/bin/resettable-service-entrypoint.sh"
cmp buzz-relay/assets-src/bin/service-urls.sh "$runtime_test/runtime/bin/service-urls.sh"
cmp buzz-relay/assets-src/config-ui/server.py "$runtime_test/runtime/config-ui/server.py"
cmp buzz-relay/assets-src/config-ui/static/app.js "$runtime_test/runtime/config-ui/static/app.js"
cmp buzz-relay/assets-src/config-ui/static/index.html "$runtime_test/runtime/config-ui/static/index.html"
cmp buzz-relay/assets-src/config-ui/static/styles.css "$runtime_test/runtime/config-ui/static/styles.css"
echo "runtime asset hook ok"

ruby -e '
  require "yaml"
  require "uri"
  compose = YAML.load_file("buzz-relay/docker-compose.yml")
  services = compose.fetch("services")
  proxy = services.fetch("app_proxy").fetch("environment")
  config = services.fetch("config")
  relay = services.fetch("relay")
  postgres = services.fetch("postgres")
  minio_init = services.fetch("minio-init")
  manifest = YAML.load_file("buzz-relay/umbrel-app.yml")
  abort "app_proxy must target config" unless proxy == {"APP_HOST" => "buzz-relay_config_1", "APP_PORT" => 8080}
  abort "config must not publish a host port" if config.key?("ports")
  abort "shared gateway must not exist" if services.key?("gateway")
  abort "relay public port mapping missing" unless relay.fetch("ports") == ["${APP_BUZZ_RELAY_PUBLIC_PORT}:3000"]
  relay_env = relay.fetch("environment")
  abort "raw database URL must be built by the credential-safe wrapper" if relay_env.key?("DATABASE_URL") || relay_env.key?("REDIS_URL")
  abort "relay service password input missing" unless relay_env.key?("BUZZ_SERVICE_PASSWORD")
  abort "production NIP-98 authentication must remain enabled" unless relay_env.fetch("BUZZ_REQUIRE_AUTH_TOKEN") == "true"
  abort "closed relay membership must remain enabled" unless relay_env.fetch("BUZZ_REQUIRE_RELAY_MEMBERSHIP") == "true"
  abort "NIP-OA owner delegation must remain enabled" unless relay_env.fetch("BUZZ_ALLOW_NIP_OA_AUTH") == "true"
  entrypoint = File.read("buzz-relay/assets-src/bin/relay-entrypoint.sh")
  abort "Buzz Desktop policy-probe origins missing" unless entrypoint.include?("tauri://localhost") && entrypoint.include?("http://tauri.localhost")
  abort "runtime must derive CORS instead of trusting stale persisted values" if entrypoint.include?(%q{first_line "$CORS_ORIGINS_FILE"})
  abort "relay database host is not collision-safe" unless relay_env.fetch("BUZZ_POSTGRES_HOST") == "buzz-relay_postgres_1"
  abort "relay Redis host is not collision-safe" unless relay_env.fetch("BUZZ_REDIS_HOST") == "buzz-relay_redis_1"
  minio_aliases = services.fetch("minio").dig("networks", "default", "aliases") || []
  minio_alias = "buzz-relay-minio"
  abort "MinIO must have its package-qualified network alias" unless minio_aliases == [minio_alias]
  all_aliases = services.values.flat_map { |service| service.dig("networks", "default", "aliases") || [] }
  abort "MinIO network alias must be unique" unless all_aliases.count(minio_alias) == 1
  abort "generic dependency network alias found" if all_aliases.any? { |name| %w[postgres redis minio relay config].include?(name) }
  valid_hostname = minio_alias.length <= 253 && minio_alias.split(".").all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
  abort "MinIO network alias is not an RFC-valid hostname" unless valid_hostname
  minio_endpoint = relay_env.fetch("BUZZ_S3_ENDPOINT")
  parsed_endpoint = URI.parse(minio_endpoint)
  abort "relay MinIO URL is invalid" unless parsed_endpoint.scheme == "http" && parsed_endpoint.host == minio_alias && parsed_endpoint.port == 9000 && parsed_endpoint.userinfo.nil? && [nil, "", "/"].include?(parsed_endpoint.path) && parsed_endpoint.query.nil? && parsed_endpoint.fragment.nil?
  abort "config health host is not collision-safe" unless config.fetch("environment").fetch("BUZZ_RELAY_HEALTH_HOST") == "buzz-relay_relay_1"
  abort "MinIO initializer endpoint differs from relay" unless minio_init.fetch("environment").fetch("BUZZ_S3_ENDPOINT") == minio_endpoint
  postgres_health = postgres.fetch("healthcheck").fetch("test").join(" ")
  abort "Postgres healthcheck must authenticate over TCP" unless postgres_health.include?("PGPASSWORD") && postgres_health.include?("psql -h 127.0.0.1") && postgres_health.include?("SELECT 1")
  redis_health = services.fetch("redis").fetch("healthcheck").fetch("test").join(" ")
  abort "Redis healthcheck must use credential-safe environment authentication" unless redis_health.include?("REDISCLI_AUTH") && !redis_health.include?("redis-cli -a")
  abort "generic dependency URL leaked into Compose" if File.read("buzz-relay/docker-compose.yml").match?(%r{@(?:postgres|redis):|http://minio:})
  abort "launcher must use the authenticated app-proxy port" unless manifest.fetch("port") == 38633 && manifest.fetch("path") == ""
  abort "public port export missing" unless File.read("buzz-relay/exports.sh").include?(%q{APP_BUZZ_RELAY_PUBLIC_PORT="38634"})
  abort "not-ready warning missing" unless File.read("README.md").include?("NOT READY FOR INSTALLATION") && manifest.fetch("description").include?("NOT READY FOR INSTALLATION")
'
echo "admin and relay endpoints are statically separated"

if rg -n '\./scripts/|\./config-ui/' buzz-relay; then
  echo "non-update-safe runtime mount found" >&2
  exit 1
fi

echo "local static validation ok"
