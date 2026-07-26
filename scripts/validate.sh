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
bash -n buzz-relay/assets-src/bin/operations-entrypoint.sh
bash -n buzz-relay/assets-src/bin/service-urls.sh
bash -n buzz-relay/exports.sh
bash -n buzz-relay/hooks/pre-start
bash -n scripts/validate.sh
bash -n scripts/run-umbrel-lint.sh
bash -n tests/test_service_urls.sh
bash -n tests/test_backup_worker.sh
bash -n tests/test_setup_busybox.sh

python3 -m py_compile scripts/check_upstream_buzz.py
python3 -m py_compile scripts/generate_runtime_assets.py
python3 -m py_compile buzz-relay/assets-src/config-ui/server.py
python3 scripts/generate_runtime_assets.py --check
python3 -m unittest discover -s tests -v
tests/test_service_urls.sh
tests/test_backup_worker.sh
if command -v docker >/dev/null 2>&1; then
  tests/test_setup_busybox.sh
else
  echo "BusyBox setup verification skipped: docker is unavailable"
fi

runtime_test="$(mktemp -d)"
trap 'rm -rf "$runtime_test"' EXIT
cp buzz-relay/asset-*.template "$runtime_test/"
for template in "$runtime_test"/*.template; do
  cp "$template" "${template%.template}"
done
mkdir -p "$runtime_test/runtime/config-ui/static"
printf 'Client endpoint\n' > "$runtime_test/runtime/config-ui/static/index.html"
package_version="$(ruby -e 'require "yaml"; print YAML.load_file("buzz-relay/umbrel-app.yml").fetch("version")')"
APP_DATA_DIR="$runtime_test" APP_VERSION="$package_version" buzz-relay/hooks/pre-start >/dev/null
cmp buzz-relay/assets-src/bin/buzz-admin.sh "$runtime_test/runtime/bin/buzz-admin.sh"
cmp buzz-relay/assets-src/bin/minio-init-entrypoint.sh "$runtime_test/runtime/bin/minio-init-entrypoint.sh"
cmp buzz-relay/assets-src/bin/operations-entrypoint.sh "$runtime_test/runtime/bin/operations-entrypoint.sh"
cmp buzz-relay/assets-src/bin/relay-entrypoint.sh "$runtime_test/runtime/bin/relay-entrypoint.sh"
cmp buzz-relay/assets-src/bin/resettable-service-entrypoint.sh "$runtime_test/runtime/bin/resettable-service-entrypoint.sh"
cmp buzz-relay/assets-src/bin/service-urls.sh "$runtime_test/runtime/bin/service-urls.sh"
cmp buzz-relay/assets-src/config-ui/server.py "$runtime_test/runtime/config-ui/server.py"
cmp buzz-relay/assets-src/config-ui/static/app.js "$runtime_test/runtime/config-ui/static/app.js"
cmp buzz-relay/assets-src/config-ui/static/index.html "$runtime_test/runtime/config-ui/static/index.html"
cmp buzz-relay/assets-src/config-ui/static/styles.css "$runtime_test/runtime/config-ui/static/styles.css"
[[ "$(sed -n '1p' "$runtime_test/runtime/package-version")" == "$package_version" ]]
runtime_ui_inode="$(ls -di "$runtime_test/runtime/config-ui" | awk '{print $1}')"
printf 'Client endpoint\n' > "$runtime_test/runtime/config-ui/static/index.html"
APP_DATA_DIR="$runtime_test" APP_VERSION="$package_version" BUZZ_RUNTIME_IN_PLACE=1 buzz-relay/hooks/pre-start >/dev/null
[[ "$(ls -di "$runtime_test/runtime/config-ui" | awk '{print $1}')" == "$runtime_ui_inode" ]]
cmp buzz-relay/assets-src/config-ui/static/index.html "$runtime_test/runtime/config-ui/static/index.html"
echo "runtime asset hook ok"

ruby -e '
  require "yaml"
  require "uri"
  compose = YAML.load_file("buzz-relay/docker-compose.yml")
  services = compose.fetch("services")
  proxy = services.fetch("app_proxy").fetch("environment")
  config = services.fetch("config")
  setup = services.fetch("setup")
  relay = services.fetch("relay")
  operations = services.fetch("operations")
  postgres = services.fetch("postgres")
  minio_init = services.fetch("minio-init")
  manifest = YAML.load_file("buzz-relay/umbrel-app.yml")
  abort "app_proxy must target config" unless proxy == {"APP_HOST" => "buzz-relay_config_1", "APP_PORT" => 8080}
  abort "app_proxy must wait for a healthy config service" unless services.fetch("app_proxy").dig("depends_on", "config", "condition") == "service_healthy"
  abort "config must not publish a host port" if config.key?("ports")
  abort "config healthcheck missing" unless config.dig("healthcheck", "test")&.join(" ")&.include?("http://127.0.0.1:8080/")
  abort "config restart retries must be bounded" unless config.fetch("restart") == "on-failure:3"
  setup_command = setup.fetch("command")
  abort "setup must verify runtime assets on every container start" unless setup_command.include?("BUZZ_RUNTIME_IN_PLACE=1 /package/hooks/pre-start")
  abort "setup must emit an actionable staging failure" unless setup_command.include?("verified runtime asset staging failed")
  abort "setup failure must be terminal" unless setup.fetch("restart") == "no"
  abort "setup runtime destination must be writable" unless setup.fetch("volumes").include?("${APP_DATA_DIR}/runtime:/package/runtime")
  abort "setup data destination must be writable" unless setup.fetch("volumes").include?("${APP_DATA_DIR}/data:/package/data")
  abort "setup hook must be mounted read-only" unless setup.fetch("volumes").include?("${APP_DATA_DIR}/hooks:/package/hooks:ro")
  abort "setup checksum source must be mounted read-only" unless setup.fetch("volumes").include?("${APP_DATA_DIR}/asset-sha256.template:/package/asset-sha256:ro")
  abort "runtime verification must use portable BusyBox checksum syntax" unless File.read("buzz-relay/hooks/pre-start").scan(/sha256sum -c /).length == 2
  abort "GNU-only checksum syntax is not allowed" if File.read("buzz-relay/hooks/pre-start").include?("sha256sum --check")
  abort "operations worker must not publish a host port" if operations.key?("ports")
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
  abort "config metrics host is not internal" unless config.fetch("environment").fetch("BUZZ_RELAY_METRICS_HOST") == "buzz-relay_relay_1"
  abort "config MinIO health host must use the valid package alias" unless config.fetch("environment").fetch("BUZZ_MINIO_HEALTH_HOST") == minio_alias
  abort "MinIO initializer endpoint differs from relay" unless minio_init.fetch("environment").fetch("BUZZ_S3_ENDPOINT") == minio_endpoint
  postgres_health = postgres.fetch("healthcheck").fetch("test").join(" ")
  abort "Postgres healthcheck must authenticate over TCP" unless postgres_health.include?("PGPASSWORD") && postgres_health.include?("psql -h 127.0.0.1") && postgres_health.include?("SELECT 1")
  redis_health = services.fetch("redis").fetch("healthcheck").fetch("test").join(" ")
  abort "Redis healthcheck must use credential-safe environment authentication" unless redis_health.include?("REDISCLI_AUTH") && !redis_health.include?("redis-cli -a")
  abort "generic dependency URL leaked into Compose" if File.read("buzz-relay/docker-compose.yml").match?(%r{@(?:postgres|redis):|http://minio:})
  abort "launcher must use the authenticated app-proxy port" unless manifest.fetch("port") == 38633 && manifest.fetch("path") == ""
  abort "generated download archives must be excluded from system backups" unless manifest.fetch("backupIgnore") == ["data/backups/*"]
  abort "package version mismatch in config worker" unless config.fetch("environment").fetch("BUZZ_PACKAGE_VERSION") == manifest.fetch("version")
  abort "package version mismatch in setup worker" unless setup.fetch("environment").fetch("BUZZ_PACKAGE_VERSION") == manifest.fetch("version")
  abort "package version mismatch in operations worker" unless operations.fetch("environment").fetch("BUZZ_PACKAGE_VERSION") == manifest.fetch("version")
  abort "operations worker must use the pinned PostgreSQL image" unless operations.fetch("image") == postgres.fetch("image")
  abort "operations worker must receive the generated service password" unless operations.fetch("environment").fetch("POSTGRES_PASSWORD") == "${APP_PASSWORD}"
  abort "operations backup destination must be writable" unless operations.fetch("volumes").include?("${APP_DATA_DIR}/data/backups:/backups")
  %w[postgres redis minio git git-cache].each do |name|
    mount = "${APP_DATA_DIR}/data/#{name}:/source/#{name}:ro"
    abort "operations source mount must be read-only: #{name}" unless operations.fetch("volumes").include?(mount)
  end
  operations_script = File.read("buzz-relay/assets-src/bin/operations-entrypoint.sh")
  abort "operations metadata must remain readable by the admin service" unless operations_script.include?(%q{chmod 0644 "$destination"}) && operations_script.include?(%q{chmod 0644 "$STORAGE_FILE"})
  abort "backup must use a logical PostgreSQL dump" unless operations_script.include?("pg_dump") && operations_script.include?("--format=custom")
  abort "backup archive must include component checksums" unless operations_script.include?("SHA256SUMS") && operations_script.include?("sha256sum manifest.json")
  abort "backup must not archive transient Redis or git cache" if operations_script.match?(/tar .*source\/(?:redis|git-cache)/)
  abort "relay backup pause handshake missing" unless File.read("buzz-relay/assets-src/bin/relay-entrypoint.sh").include?("backup-paused")
  abort "MinIO backup pause handshake missing" unless File.read("buzz-relay/assets-src/bin/resettable-service-entrypoint.sh").include?("pause_for_backup")
  server = File.read("buzz-relay/assets-src/config-ui/server.py")
  abort "status metadata reads must tolerate root-owned legacy files" unless server.include?("except OSError:")
  abort "static assets must use the package version as a cache key" unless server.include?("__BUZZ_ASSET_VERSION__")
  abort "canonical Community URL must be immutable after initialization" unless server.include?("requiresNewCommunityReset")
  abort "restore upload must not be exposed before runtime validation" if server.include?("restore-upload") || File.read("buzz-relay/assets-src/config-ui/static/index.html").include?(%q{type="file"})
  abort "public port export missing" unless File.read("buzz-relay/exports.sh").include?(%q{APP_BUZZ_RELAY_PUBLIC_PORT="38634"})
  abort "not-ready warning missing" unless File.read("README.md").include?("NOT READY FOR INSTALLATION") && manifest.fetch("description").include?("NOT READY FOR INSTALLATION")
'
echo "admin and relay endpoints are statically separated"

if rg -n '\./scripts/|\./config-ui/' buzz-relay; then
  echo "non-update-safe runtime mount found" >&2
  exit 1
fi

echo "local static validation ok"
