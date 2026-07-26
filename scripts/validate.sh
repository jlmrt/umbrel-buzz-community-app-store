#!/usr/bin/env bash
set -euo pipefail

ruby -e 'require "yaml"; %w[umbrel-app-store.yml buzz-relay/umbrel-app.yml buzz-relay/docker-compose.yml .github/workflows/check-buzz-upstream.yml].each { |path| YAML.load_file(path); puts "yaml ok: #{path}" }'
python3 -m json.tool .github/upstream-buzz.json >/dev/null
echo "json ok: .github/upstream-buzz.json"

bash -n buzz-relay/scripts/relay-entrypoint.sh
bash -n buzz-relay/scripts/buzz-admin.sh
bash -n scripts/validate.sh
python3 -m py_compile scripts/check_upstream_buzz.py
echo "shell ok"
