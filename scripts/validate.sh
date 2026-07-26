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
bash -n buzz-relay/hooks/pre-start
bash -n scripts/validate.sh
bash -n scripts/run-umbrel-lint.sh

python3 -m py_compile scripts/check_upstream_buzz.py
python3 -m py_compile scripts/generate_runtime_assets.py
python3 -m py_compile buzz-relay/assets-src/config-ui/server.py
python3 scripts/generate_runtime_assets.py --check
python3 -m unittest discover -s tests -v

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
cmp buzz-relay/assets-src/config-ui/server.py "$runtime_test/runtime/config-ui/server.py"
cmp buzz-relay/assets-src/config-ui/static/app.js "$runtime_test/runtime/config-ui/static/app.js"
cmp buzz-relay/assets-src/config-ui/static/index.html "$runtime_test/runtime/config-ui/static/index.html"
cmp buzz-relay/assets-src/config-ui/static/styles.css "$runtime_test/runtime/config-ui/static/styles.css"
cmp buzz-relay/assets-src/gateway/nginx.conf "$runtime_test/runtime/gateway/nginx.conf"
echo "runtime asset hook ok"

if rg -n '\./scripts/|\./config-ui/' buzz-relay; then
  echo "non-update-safe runtime mount found" >&2
  exit 1
fi

echo "local static validation ok"
