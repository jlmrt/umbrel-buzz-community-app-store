#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umbrel_apps_commit="e3fdfc8f9384407c534daca1c37dd53409bfc843"
cached_checkout="${repo_root}/work/umbrel-apps"
temporary=""

cleanup() {
  if [[ -n "$temporary" ]]; then
    rm -rf "$temporary"
  fi
}
trap cleanup EXIT

if [[ -d "${cached_checkout}/.git" ]] &&
   [[ "$(git -C "$cached_checkout" rev-parse HEAD)" == "$umbrel_apps_commit" ]]; then
  linter_checkout="$cached_checkout"
else
  temporary="$(mktemp -d)"
  git -C "$temporary" init --quiet
  git -C "$temporary" remote add origin https://github.com/getumbrel/umbrel-apps.git
  git -C "$temporary" fetch --quiet --depth 1 origin "$umbrel_apps_commit"
  git -C "$temporary" checkout --quiet FETCH_HEAD
  linter_checkout="$temporary"
fi

if [[ ! -d "${linter_checkout}/node_modules/yaml" ]]; then
  npm --prefix "$linter_checkout" ci --ignore-scripts --no-audit --no-fund
fi

node "${linter_checkout}/.tools/lint-apps.mjs" \
  --root "$repo_root" \
  --check-images \
  buzz-relay
