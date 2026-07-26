#!/usr/bin/env python3
"""Generate Umbrel-update-safe base64 templates for runtime assets."""

from __future__ import annotations

import argparse
import base64
import hashlib
import sys
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "buzz-relay"

ASSETS = {
    "bin/buzz-admin.sh": "assets-src/bin/buzz-admin.sh",
    "bin/minio-init-entrypoint.sh": "assets-src/bin/minio-init-entrypoint.sh",
    "bin/relay-entrypoint.sh": "assets-src/bin/relay-entrypoint.sh",
    "bin/resettable-service-entrypoint.sh": "assets-src/bin/resettable-service-entrypoint.sh",
    "config-ui/server.py": "assets-src/config-ui/server.py",
    "config-ui/static/app.js": "assets-src/config-ui/static/app.js",
    "config-ui/static/index.html": "assets-src/config-ui/static/index.html",
    "config-ui/static/styles.css": "assets-src/config-ui/static/styles.css",
    "gateway/nginx.conf": "assets-src/gateway/nginx.conf",
}


def template_name(runtime_path: str) -> str:
    return "asset-" + runtime_path.replace("/", "-") + ".b64.template"


def generated_files() -> dict[Path, bytes]:
    generated: dict[Path, bytes] = {}
    checksums: list[str] = []
    for runtime_path, source_path in sorted(ASSETS.items()):
        source = (APP_DIR / source_path).read_bytes()
        encoded = base64.b64encode(source).decode("ascii")
        wrapped = textwrap.fill(encoded, width=76) + "\n"
        generated[APP_DIR / template_name(runtime_path)] = wrapped.encode("ascii")
        checksums.append(f"{hashlib.sha256(source).hexdigest()}  {runtime_path}")
    generated[APP_DIR / "asset-sha256.template"] = (
        "\n".join(checksums) + "\n"
    ).encode("ascii")
    return generated


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="fail when generated files are stale"
    )
    args = parser.parse_args()

    expected = generated_files()
    stale: list[Path] = []
    for path, content in expected.items():
        if not path.exists() or path.read_bytes() != content:
            stale.append(path)
            if not args.check:
                path.write_bytes(content)

    expected_names = {path.name for path in expected}
    unexpected = [
        path
        for path in APP_DIR.glob("asset-*.template")
        if path.name not in expected_names
    ]
    if not args.check:
        for path in unexpected:
            path.unlink()

    if args.check and (stale or unexpected):
        for path in stale:
            print(f"stale generated asset: {path.relative_to(ROOT)}", file=sys.stderr)
        for path in unexpected:
            print(f"unexpected generated asset: {path.relative_to(ROOT)}", file=sys.stderr)
        return 1

    action = "verified" if args.check else "generated"
    print(f"{action} {len(expected)} Umbrel runtime asset templates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
