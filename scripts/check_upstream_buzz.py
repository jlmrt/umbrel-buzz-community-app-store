#!/usr/bin/env python3
"""Open-review updater for the Buzz Umbrel package.

This script checks Block's official Buzz upstream, verifies that the target
GHCR image tag is pullable, updates local package files, and writes a PR body.
It never commits, pushes, merges, or publishes an update by itself.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
COMPOSE_PATH = ROOT / "buzz-relay" / "docker-compose.yml"
MANIFEST_PATH = ROOT / "buzz-relay" / "umbrel-app.yml"
LOCK_PATH = ROOT / ".github" / "upstream-buzz.json"

UPSTREAM_REPO = "block/buzz"
UPSTREAM_FILES = [
    "deploy/compose/README.md",
    "deploy/compose/.env.example",
    "deploy/compose/compose.yml",
]

IMAGE_RE = re.compile(
    r"ghcr\.io/block/buzz:sha-[0-9a-f]+@sha256:[0-9a-f]+", re.IGNORECASE
)


class UpstreamUnavailable(RuntimeError):
    pass


def request_json(url: str, headers: dict[str, str] | None = None) -> Any:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def github_headers() -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "umbrel-buzz-upstream-checker",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def github_api(path: str) -> Any:
    return request_json(f"https://api.github.com{path}", github_headers())


def github_api_or_none(path: str) -> Any | None:
    try:
        return github_api(path)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def resolve_tag_commit(tag_name: str) -> str:
    tag_ref = github_api(f"/repos/{UPSTREAM_REPO}/git/ref/tags/{tag_name}")
    obj = tag_ref["object"]
    if obj["type"] == "commit":
        return obj["sha"]
    if obj["type"] == "tag":
        tag_obj = request_json(obj["url"], github_headers())
        return tag_obj["object"]["sha"]
    raise UpstreamUnavailable(f"Unexpected tag object type for {tag_name}: {obj['type']}")


def select_target(strategy: str) -> tuple[str, str, dict[str, Any] | None]:
    latest_release = github_api_or_none(f"/repos/{UPSTREAM_REPO}/releases/latest")

    if strategy == "latest-release":
        if not latest_release:
            raise UpstreamUnavailable("No official Buzz release is available.")
        return latest_release["tag_name"], resolve_tag_commit(latest_release["tag_name"]), latest_release

    if strategy != "default-branch":
        raise ValueError(f"Unsupported strategy: {strategy}")

    repo = github_api(f"/repos/{UPSTREAM_REPO}")
    default_branch = repo["default_branch"]
    branch = github_api(f"/repos/{UPSTREAM_REPO}/branches/{default_branch}")
    return default_branch, branch["commit"]["sha"], latest_release


def ghcr_digest(repo: str, tag: str) -> str | None:
    scope = f"repository:{repo}:pull"
    token_url = "https://ghcr.io/token?" + urllib.parse.urlencode(
        {"service": "ghcr.io", "scope": scope}
    )
    token = request_json(token_url)["token"]
    accept = ", ".join(
        [
            "application/vnd.oci.image.index.v1+json",
            "application/vnd.docker.distribution.manifest.list.v2+json",
            "application/vnd.oci.image.manifest.v1+json",
            "application/vnd.docker.distribution.manifest.v2+json",
        ]
    )
    req = urllib.request.Request(
        f"https://ghcr.io/v2/{repo}/manifests/{tag}",
        headers={"Authorization": f"Bearer {token}", "Accept": accept},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.headers.get("Docker-Content-Digest")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise


def fetch_upstream_file(commit: str, path: str) -> str:
    url = f"https://raw.githubusercontent.com/{UPSTREAM_REPO}/{commit}/{path}"
    req = urllib.request.Request(url, headers={"User-Agent": "umbrel-buzz-upstream-checker"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.read().decode("utf-8")


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def read_lock() -> dict[str, Any]:
    if not LOCK_PATH.exists():
        return {}
    return json.loads(LOCK_PATH.read_text(encoding="utf-8"))


def write_lock(
    strategy: str,
    target_ref: str,
    target_commit: str,
    image: str,
    latest_release: dict[str, Any] | None,
    file_hashes: dict[str, str],
) -> None:
    data = {
        "upstream_repo": UPSTREAM_REPO,
        "strategy": strategy,
        "target_ref": target_ref,
        "target_commit": target_commit,
        "image": image,
        "latest_release": release_snapshot(latest_release),
        "checked_files": file_hashes,
    }
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOCK_PATH.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def release_snapshot(release: dict[str, Any] | None) -> dict[str, str] | None:
    if not release:
        return None
    return {
        "tag_name": release.get("tag_name", ""),
        "published_at": release.get("published_at", ""),
        "html_url": release.get("html_url", ""),
    }


def package_version(latest_release: dict[str, Any] | None, short_sha: str) -> str:
    if latest_release and latest_release.get("tag_name"):
        base = latest_release["tag_name"].removeprefix("v")
    else:
        base = "upstream"
    return f"{base}-{short_sha}"


def update_compose(image: str) -> bool:
    text = COMPOSE_PATH.read_text(encoding="utf-8")
    updated, count = IMAGE_RE.subn(image, text, count=1)
    if count != 1:
        raise RuntimeError(f"Could not find exactly one Buzz image pin in {COMPOSE_PATH}")
    if updated != text:
        COMPOSE_PATH.write_text(updated, encoding="utf-8")
        return True
    return False


def replace_folded_block(text: str, key: str, body_lines: list[str]) -> str:
    lines = text.splitlines()
    output: list[str] = []
    index = 0
    found = False
    while index < len(lines):
        line = lines[index]
        if line == f"{key}: >-":
            found = True
            output.append(line)
            output.extend(f"  {body_line}" if body_line else "" for body_line in body_lines)
            index += 1
            while index < len(lines) and (lines[index].startswith(" ") or lines[index] == ""):
                index += 1
            continue
        output.append(line)
        index += 1
    if not found:
        raise RuntimeError(f"Could not find folded YAML block {key}: >- in {MANIFEST_PATH}")
    return "\n".join(output) + "\n"


def update_manifest(version: str, target_ref: str, short_sha: str, image: str, latest_release: dict[str, Any] | None) -> bool:
    text = MANIFEST_PATH.read_text(encoding="utf-8")
    updated, count = re.subn(r'(?m)^version: "[^"]+"$', f'version: "{version}"', text, count=1)
    if count != 1:
        raise RuntimeError(f"Could not update manifest version in {MANIFEST_PATH}")

    release_ref = "no GitHub release metadata found"
    if latest_release:
        release_ref = f"{latest_release.get('tag_name')} published {latest_release.get('published_at')}"

    notes = [
        f"Tracks official Block Buzz upstream {target_ref} at commit {short_sha}.",
        f"Relay image is pinned to {image}.",
        f"Latest upstream release reference: {release_ref}.",
        "Review the generated pull request and upstream deployment-file drift before merging.",
    ]
    updated = replace_folded_block(updated, "releaseNotes", notes)

    if updated != text:
        MANIFEST_PATH.write_text(updated, encoding="utf-8")
        return True
    return False


def write_pr_body(
    path: Path,
    strategy: str,
    target_ref: str,
    target_commit: str,
    image: str,
    latest_release: dict[str, Any] | None,
    file_hashes: dict[str, str],
    prior_lock: dict[str, Any],
) -> None:
    short_sha = target_commit[:7]
    release_url = latest_release.get("html_url") if latest_release else ""
    release_line = (
        f"- Latest release reference: [{latest_release['tag_name']}]({release_url})"
        if latest_release and release_url
        else "- Latest release reference: unavailable"
    )

    drift_lines = []
    old_hashes = prior_lock.get("checked_files", {}) if prior_lock else {}
    for file_path in UPSTREAM_FILES:
        old_hash = old_hashes.get(file_path, "")
        new_hash = file_hashes[file_path]
        if old_hash and old_hash != new_hash:
            status = "changed"
        elif old_hash == new_hash:
            status = "unchanged"
        else:
            status = "new baseline"
        drift_lines.append(f"- `{file_path}`: {status}")

    body = f"""
    This PR was opened by the conservative Buzz upstream monitor.

    ## Proposed Update

    - Strategy: `{strategy}`
    - Upstream target: `block/buzz` `{target_ref}` at `{short_sha}`
    - Relay image: `{image}`
    {release_line}

    ## Deployment File Drift

    {chr(10).join(drift_lines)}

    ## Required Human Review

    - Confirm the Umbrel app has already been proven running before merging.
    - Read Block Buzz upstream release notes and production `deploy/compose/` changes.
    - Confirm no new required environment variables, ports, volumes, or services were added.
    - Test a fresh Umbrel install and an upgrade with existing `app-data`.
    - Do not enable auto-merge for this workflow.

    The workflow only opens this PR. It does not publish, merge, or apply updates
    blindly.
    """
    path.write_text(textwrap.dedent(body).strip() + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--strategy", choices=["default-branch", "latest-release"], default="default-branch")
    parser.add_argument("--pr-body", type=Path, default=ROOT / ".github" / "upstream-buzz-pr-body.md")
    args = parser.parse_args()

    target_ref, target_commit, latest_release = select_target(args.strategy)
    short_sha = target_commit[:7]
    image_tag = f"sha-{short_sha}"
    digest = ghcr_digest("block/buzz", image_tag)
    if not digest:
        print(
            f"No public GHCR image found for ghcr.io/block/buzz:{image_tag}; "
            "leaving package unchanged.",
            file=sys.stderr,
        )
        return 0

    image = f"ghcr.io/block/buzz:{image_tag}@{digest}"
    file_hashes = {
        path: sha256_text(fetch_upstream_file(target_commit, path))
        for path in UPSTREAM_FILES
    }
    prior_lock = read_lock()

    update_compose(image)
    update_manifest(
        package_version(latest_release, short_sha),
        target_ref,
        short_sha,
        image,
        latest_release,
    )
    write_lock(args.strategy, target_ref, target_commit, image, latest_release, file_hashes)
    write_pr_body(
        args.pr_body,
        args.strategy,
        target_ref,
        target_commit,
        image,
        latest_release,
        file_hashes,
        prior_lock,
    )

    checked_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    print(f"Checked {UPSTREAM_REPO} at {target_ref} {short_sha} on {checked_at}")
    print(f"Verified image {image}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except UpstreamUnavailable as exc:
        print(f"Upstream unavailable: {exc}", file=sys.stderr)
        raise SystemExit(0)
