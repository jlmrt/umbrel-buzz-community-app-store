#!/usr/bin/env python3
"""Local configuration UI for the Umbrel Buzz relay package."""

from __future__ import annotations

import hashlib
import http.client
import json
import mimetypes
import os
import re
import stat
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


CONFIG_DIR = Path(os.environ.get("BUZZ_CONFIG_DIR", "/config"))
STATIC_DIR = Path(os.environ.get("BUZZ_SETUP_STATIC_DIR", "/app/static"))
RELAY_HEALTH_HOST = os.environ.get("BUZZ_RELAY_HEALTH_HOST", "buzz-relay_relay_1")
RELAY_HEALTH_PORT = int(os.environ.get("BUZZ_RELAY_HEALTH_PORT", "8080"))
RELAY_METRICS_HOST = os.environ.get("BUZZ_RELAY_METRICS_HOST", RELAY_HEALTH_HOST)
RELAY_METRICS_PORT = int(os.environ.get("BUZZ_RELAY_METRICS_PORT", "9102"))
MINIO_HEALTH_HOST = os.environ.get("BUZZ_MINIO_HEALTH_HOST", "buzz-relay-minio")
MINIO_HEALTH_PORT = int(os.environ.get("BUZZ_MINIO_HEALTH_PORT", "9000"))
DEFAULT_RELAY_URL = os.environ.get("BUZZ_DEFAULT_RELAY_URL", "")
PACKAGE_VERSION = os.environ.get("BUZZ_PACKAGE_VERSION", "unknown")
BACKUP_DIR = Path(os.environ.get("BUZZ_BACKUP_DIR", "/backups"))
BACKUP_MAX_BYTES = int(os.environ.get("BUZZ_BACKUP_MAX_BYTES", "53687091200"))

OWNER_FILE = CONFIG_DIR / "relay-owner-pubkey"
PENDING_OWNER_FILE = CONFIG_DIR / "pending-owner-pubkey"
RELAY_URL_FILE = CONFIG_DIR / "relay-url"
MEDIA_URL_FILE = CONFIG_DIR / "media-base-url"
CORS_FILE = CONFIG_DIR / "cors-origins"
COMMUNITY_MODE_FILE = CONFIG_DIR / "community-mode"
RESET_REQUEST_FILE = CONFIG_DIR / "reset-request"
RESET_COMPLETED_FILE = CONFIG_DIR / "reset-completed"
RESET_ERROR_FILE = CONFIG_DIR / "reset-error"
RESTART_REQUEST_FILE = CONFIG_DIR / "restart-request"
RESTART_COMPLETED_FILE = CONFIG_DIR / "restart-completed"
RELAY_STATE_FILE = CONFIG_DIR / "relay-state"
BACKUP_REQUEST_FILE = CONFIG_DIR / "backup-request"
BACKUP_STATE_FILE = CONFIG_DIR / "backup-state"
BACKUP_PROGRESS_FILE = CONFIG_DIR / "backup-progress"
BACKUP_MESSAGE_FILE = CONFIG_DIR / "backup-message"
BACKUP_CURRENT_ID_FILE = CONFIG_DIR / "backup-current-id"
BACKUP_LATEST_NAME_FILE = CONFIG_DIR / "backup-latest-name"
BACKUP_LATEST_SIZE_FILE = CONFIG_DIR / "backup-latest-size"
BACKUP_LATEST_SHA_FILE = CONFIG_DIR / "backup-latest-sha256"
BACKUP_LATEST_CREATED_FILE = CONFIG_DIR / "backup-latest-created-at"
OPERATIONS_HEARTBEAT_FILE = CONFIG_DIR / "operations-heartbeat"
STORAGE_STATS_FILE = CONFIG_DIR / "storage-stats"
ACTIVITY_COUNT_FILE = CONFIG_DIR / "activity-observed-count"
ACTIVITY_AT_FILE = CONFIG_DIR / "activity-observed-at"

HEX_KEY_RE = re.compile(r"^[0-9a-fA-F]{64}$")
BACKUP_NAME_RE = re.compile(r"^buzz-relay-backup-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\.tar$")
PROMETHEUS_SAMPLE_RE = re.compile(
    r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{[^\r\n]*\})?\s+([-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)$"
)
BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_LOOKUP = {char: index for index, char in enumerate(BECH32_CHARSET)}
WRITE_LOCK = threading.Lock()
STATS_LOCK = threading.Lock()
ACTIVITY_LOCK = threading.Lock()
STATS_CACHE: tuple[float, dict[str, object]] | None = None
DESKTOP_ORIGINS = ("tauri://localhost", "http://tauri.localhost")


class InputError(ValueError):
    """A safe validation error that can be returned to the UI."""


def read_first_line(path: Path) -> str:
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            value = line.strip()
            if value and not value.startswith("#"):
                return value
    except FileNotFoundError:
        pass
    return ""


def atomic_write(path: Path, value: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(value.rstrip("\n") + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def bech32_polymod(values: list[int]) -> int:
    generators = (0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)
    checksum = 1
    for value in values:
        top = checksum >> 25
        checksum = ((checksum & 0x1FFFFFF) << 5) ^ value
        for index, generator in enumerate(generators):
            if (top >> index) & 1:
                checksum ^= generator
    return checksum


def bech32_hrp_expand(hrp: str) -> list[int]:
    return [ord(char) >> 5 for char in hrp] + [0] + [ord(char) & 31 for char in hrp]


def bech32_checksum(hrp: str, data: list[int]) -> list[int]:
    values = bech32_hrp_expand(hrp) + data + [0] * 6
    polymod = bech32_polymod(values) ^ 1
    return [(polymod >> (5 * (5 - index))) & 31 for index in range(6)]


def convert_bits(
    values: bytes | list[int], from_bits: int, to_bits: int, pad: bool
) -> list[int]:
    accumulator = 0
    bit_count = 0
    result: list[int] = []
    maximum_value = (1 << to_bits) - 1
    maximum_accumulator = (1 << (from_bits + to_bits - 1)) - 1
    for value in values:
        if value < 0 or value >> from_bits:
            raise InputError("Invalid Bech32 data.")
        accumulator = ((accumulator << from_bits) | value) & maximum_accumulator
        bit_count += from_bits
        while bit_count >= to_bits:
            bit_count -= to_bits
            result.append((accumulator >> bit_count) & maximum_value)
    if pad:
        if bit_count:
            result.append((accumulator << (to_bits - bit_count)) & maximum_value)
    elif bit_count >= from_bits or ((accumulator << (to_bits - bit_count)) & maximum_value):
        raise InputError("Invalid Bech32 padding.")
    return result


def bech32_encode(hrp: str, payload: bytes) -> str:
    data = convert_bits(payload, 8, 5, True)
    combined = data + bech32_checksum(hrp, data)
    return hrp + "1" + "".join(BECH32_CHARSET[value] for value in combined)


def bech32_decode(value: str) -> tuple[str, bytes]:
    if not value or (value.lower() != value and value.upper() != value):
        raise InputError("The npub must not mix uppercase and lowercase characters.")
    normalized = value.lower()
    separator = normalized.rfind("1")
    if separator < 1 or separator + 7 > len(normalized):
        raise InputError("Invalid Bech32 public key.")
    hrp = normalized[:separator]
    try:
        data = [BECH32_LOOKUP[char] for char in normalized[separator + 1 :]]
    except KeyError as exc:
        raise InputError("Invalid Bech32 public key.") from exc
    if bech32_polymod(bech32_hrp_expand(hrp) + data) != 1:
        raise InputError("The npub checksum is invalid.")
    payload = bytes(convert_bits(data[:-6], 5, 8, False))
    return hrp, payload


def parse_public_key(raw_value: object) -> tuple[str, str, bool]:
    if not isinstance(raw_value, str):
        raise InputError("Enter a Nostr public key.")
    value = raw_value.strip()
    if value.lower().startswith("nostr:"):
        value = value[6:]
    lowered = value.lower()
    if lowered.startswith("nsec") or "private key" in lowered:
        raise InputError("Private keys and nsec values are rejected. Enter an npub or public-key hex.")
    if HEX_KEY_RE.fullmatch(value):
        public_hex = value.lower()
        return public_hex, bech32_encode("npub", bytes.fromhex(public_hex)), True
    if lowered.startswith("npub1"):
        hrp, payload = bech32_decode(value)
        if hrp != "npub" or len(payload) != 32:
            raise InputError("Enter a valid 32-byte npub.")
        return payload.hex(), bech32_encode("npub", payload), False
    raise InputError("Enter an npub or a 64-character hexadecimal Nostr public key.")


def validate_relay_url(raw_value: object) -> str:
    if not isinstance(raw_value, str) or not raw_value.strip():
        raise InputError("Relay URL is required.")
    value = raw_value.strip()
    try:
        parsed = urlsplit(value)
        _ = parsed.port
    except ValueError as exc:
        raise InputError("Relay URL has an invalid host or port.") from exc
    if parsed.scheme not in {"ws", "wss"} or not parsed.hostname:
        raise InputError("Relay URL must start with ws:// or wss:// and include a host.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise InputError("Relay URL cannot contain credentials, a query, or a fragment.")
    if parsed.path not in {"", "/"}:
        raise InputError("This package exposes Buzz at the hostname root; remove the URL path.")
    return f"{parsed.scheme}://{parsed.netloc}"


def derive_runtime_urls(relay_url: str) -> tuple[str, str]:
    parsed = urlsplit(validate_relay_url(relay_url))
    http_scheme = "https" if parsed.scheme == "wss" else "http"
    origin = f"{http_scheme}://{parsed.netloc}"
    cors_origins = ",".join((origin, *DESKTOP_ORIGINS))
    return f"{origin}/media", cors_origins


def select_community_url(payload: dict[str, object]) -> tuple[str, str]:
    mode = payload.get("communityMode")
    if mode == "local":
        if not DEFAULT_RELAY_URL:
            raise InputError("The local Community URL could not be discovered.")
        return mode, validate_relay_url(DEFAULT_RELAY_URL)
    if mode == "public":
        relay_url = validate_relay_url(payload.get("communityUrl"))
        if not relay_url.startswith("wss://"):
            raise InputError("A public Community URL must start with wss://.")
        return mode, relay_url
    raise InputError("Choose Local testing or Public community.")


def http_get(host: str, port: int, path: str, limit: int = 2 * 1024 * 1024) -> tuple[int, bytes]:
    connection: http.client.HTTPConnection | None = None
    try:
        connection = http.client.HTTPConnection(host, port, timeout=0.75)
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read(limit + 1)
        if len(body) > limit:
            raise ValueError("Internal response exceeded the allowed size.")
        return response.status, body
    finally:
        if connection:
            connection.close()


def internal_json(host: str, port: int, path: str) -> tuple[int | None, dict[str, object]]:
    try:
        status, body = http_get(host, port, path, 64 * 1024)
        parsed = json.loads(body.decode("utf-8"))
        return status, parsed if isinstance(parsed, dict) else {}
    except (OSError, ValueError, UnicodeDecodeError, json.JSONDecodeError, http.client.HTTPException):
        return None, {}


def parse_prometheus_metrics(body: str) -> dict[str, float]:
    totals: dict[str, float] = {}
    for line in body.splitlines():
        if not line or line.startswith("#"):
            continue
        match = PROMETHEUS_SAMPLE_RE.fullmatch(line.strip())
        if not match:
            continue
        name, raw_value = match.groups()
        try:
            value = float(raw_value)
        except ValueError:
            continue
        if value != value or value in {float("inf"), float("-inf")}:
            continue
        totals[name] = totals.get(name, 0.0) + value
    return totals


def relay_metrics() -> dict[str, int | None]:
    result: dict[str, int | None] = {
        "activeConnections": None,
        "eventsReceivedSinceStart": None,
        "requestsSinceStart": None,
        "messageCount": None,
        "channelCount": None,
        "memberCount": None,
        "userCount": None,
    }
    try:
        status, body = http_get(RELAY_METRICS_HOST, RELAY_METRICS_PORT, "/metrics")
        if status != HTTPStatus.OK:
            return result
        totals = parse_prometheus_metrics(body.decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError, http.client.HTTPException):
        return result

    mapping = {
        "activeConnections": "buzz_ws_connections_active",
        "eventsReceivedSinceStart": "buzz_events_received_total",
        "requestsSinceStart": "http_requests_total",
        "messageCount": "buzz_total_messages",
        "channelCount": "buzz_total_channels",
        "memberCount": "buzz_total_relay_members",
        "userCount": "buzz_total_users",
    }
    for output_name, metric_name in mapping.items():
        if metric_name in totals:
            result[output_name] = max(0, int(totals[metric_name]))
    observe_activity(result["eventsReceivedSinceStart"])
    return result


def observe_activity(event_count: int | None) -> None:
    if event_count is None:
        return
    with ACTIVITY_LOCK:
        try:
            previous = int(read_first_line(ACTIVITY_COUNT_FILE))
        except ValueError:
            previous = event_count
        if event_count > previous:
            atomic_write(
                ACTIVITY_AT_FILE,
                datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            )
        atomic_write(ACTIVITY_COUNT_FILE, str(event_count))


def read_storage_stats() -> dict[str, object]:
    allowed = {
        "config_kib",
        "postgres_kib",
        "redis_kib",
        "minio_kib",
        "git_kib",
        "git_cache_kib",
        "backups_kib",
    }
    values: dict[str, int] = {name: 0 for name in allowed}
    measured_at = ""
    try:
        lines = STORAGE_STATS_FILE.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        key, separator, value = line.partition("=")
        if not separator:
            continue
        if key == "measured_at":
            measured_at = value if len(value) <= 32 else ""
        elif key in allowed:
            try:
                values[key] = max(0, int(value))
            except ValueError:
                pass
    data_kib = sum(value for key, value in values.items() if key != "backups_kib")
    return {
        "measuredAt": measured_at,
        "dataBytes": data_kib * 1024,
        "backupBytes": values["backups_kib"] * 1024,
        "components": {
            "database": values["postgres_kib"] * 1024,
            "objectStorage": values["minio_kib"] * 1024,
            "repositories": values["git_kib"] * 1024,
            "cache": (values["redis_kib"] + values["git_cache_kib"]) * 1024,
            "configuration": values["config_kib"] * 1024,
        },
    }


def operations_online() -> bool:
    try:
        heartbeat = int(read_first_line(OPERATIONS_HEARTBEAT_FILE))
    except ValueError:
        return False
    return 0 <= int(time.time()) - heartbeat <= 20


def operational_stats() -> dict[str, object]:
    global STATS_CACHE
    now = time.monotonic()
    with STATS_LOCK:
        if STATS_CACHE and now - STATS_CACHE[0] < 4:
            return STATS_CACHE[1]

        status_code, relay_status = internal_json(RELAY_HEALTH_HOST, RELAY_HEALTH_PORT, "/_status")
        readiness_code, readiness = internal_json(
            RELAY_HEALTH_HOST, RELAY_HEALTH_PORT, "/_readiness"
        )
        minio_status: int | None = None
        try:
            minio_status, _ = http_get(
                MINIO_HEALTH_HOST, MINIO_HEALTH_PORT, "/minio/health/ready", 4096
            )
        except (OSError, ValueError, http.client.HTTPException):
            pass

        ready = readiness_code == HTTPStatus.OK
        postgres = True if ready else readiness.get("postgres")
        redis = True if ready else readiness.get("redis")
        if not isinstance(postgres, bool):
            postgres = None
        if not isinstance(redis, bool):
            redis = None

        metrics = relay_metrics()
        snapshot: dict[str, object] = {
            "metadataOnly": True,
            "packageVersion": PACKAGE_VERSION,
            "relayVersion": relay_status.get("version") if status_code == HTTPStatus.OK else None,
            "uptimeSeconds": relay_status.get("uptime_seconds") if status_code == HTTPStatus.OK else None,
            "relayReachable": status_code == HTTPStatus.OK,
            "relayReady": ready,
            "relayState": read_first_line(RELAY_STATE_FILE) or "unknown",
            "connectivity": {
                "postgres": postgres,
                "redis": redis,
                "objectStorage": minio_status == HTTPStatus.OK if minio_status is not None else None,
                "operationsWorker": operations_online(),
            },
            "counts": metrics,
            "lastObservedActivityAt": read_first_line(ACTIVITY_AT_FILE),
            "storage": read_storage_stats(),
        }
        STATS_CACHE = (now, snapshot)
        return snapshot


def current_key() -> tuple[str, str] | None:
    value = read_first_line(OWNER_FILE)
    try:
        public_hex, npub, _ = parse_public_key(value)
        return public_hex, npub
    except InputError:
        return None


def latest_backup_path() -> Path | None:
    name = read_first_line(BACKUP_LATEST_NAME_FILE)
    if not BACKUP_NAME_RE.fullmatch(name):
        return None
    path = BACKUP_DIR / name
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        return None
    return path


def backup_status_payload() -> dict[str, object]:
    request_id = read_first_line(BACKUP_REQUEST_FILE)
    latest_path = latest_backup_path()
    latest_size = 0
    if latest_path:
        try:
            latest_size = latest_path.stat().st_size
        except FileNotFoundError:
            latest_path = None
    try:
        progress = max(0, min(100, int(read_first_line(BACKUP_PROGRESS_FILE) or "0")))
    except ValueError:
        progress = 0
    return {
        "state": read_first_line(BACKUP_STATE_FILE) or "idle",
        "progress": progress,
        "message": read_first_line(BACKUP_MESSAGE_FILE),
        "running": bool(request_id),
        "requestId": request_id,
        "workerOnline": operations_online(),
        "maxBytes": BACKUP_MAX_BYTES,
        "latest": {
            "available": latest_path is not None,
            "name": latest_path.name if latest_path else "",
            "sizeBytes": latest_size,
            "sha256": read_first_line(BACKUP_LATEST_SHA_FILE) if latest_path else "",
            "createdAt": read_first_line(BACKUP_LATEST_CREATED_FILE) if latest_path else "",
            "downloadUrl": "/api/backups/download" if latest_path else "",
        },
        "restoreAvailable": False,
    }


def request_backup(payload: dict[str, object]) -> tuple[int, dict[str, object]]:
    if payload.get("acknowledgeSensitive") is not True:
        raise InputError("Confirm that the downloaded archive contains sensitive private data.")
    with WRITE_LOCK:
        key = current_key()
        if not key or not read_first_line(RELAY_URL_FILE):
            return HTTPStatus.CONFLICT, {"error": "Configure and start the community first."}
        if read_first_line(RESET_REQUEST_FILE) or read_first_line(RESTART_REQUEST_FILE):
            return HTTPStatus.CONFLICT, {
                "error": "Wait for the current reset or restart to finish before creating a backup."
            }
        if read_first_line(BACKUP_REQUEST_FILE):
            return HTTPStatus.CONFLICT, {"error": "A backup is already in progress."}
        if not operations_online():
            return HTTPStatus.SERVICE_UNAVAILABLE, {
                "error": "The internal backup worker is not available."
            }
        request_id = str(uuid.uuid4())
        atomic_write(BACKUP_CURRENT_ID_FILE, request_id)
        atomic_write(BACKUP_STATE_FILE, "queued")
        atomic_write(BACKUP_PROGRESS_FILE, "0")
        atomic_write(BACKUP_MESSAGE_FILE, "Backup queued")
        atomic_write(BACKUP_REQUEST_FILE, request_id)
        return HTTPStatus.ACCEPTED, {
            "message": "Backup started. Relay writes will pause briefly.",
            "backupRequestId": request_id,
        }


def status_payload() -> dict[str, object]:
    key = current_key()
    relay_url = read_first_line(RELAY_URL_FILE)
    stored_mode = read_first_line(COMMUNITY_MODE_FILE)
    try:
        local_url = validate_relay_url(DEFAULT_RELAY_URL) if DEFAULT_RELAY_URL else ""
    except InputError:
        local_url = ""
    if stored_mode not in {"local", "public"}:
        stored_mode = "local" if not relay_url or relay_url == local_url else "public"
    reset_id = read_first_line(RESET_REQUEST_FILE)
    restart_id = read_first_line(RESTART_REQUEST_FILE)
    state = read_first_line(RELAY_STATE_FILE) or ("waiting-for-configuration" if not key else "starting")
    stats = operational_stats()
    return {
        "configured": key is not None and bool(relay_url),
        "ownerConfigured": key is not None,
        "ownerHex": key[0] if key else "",
        "ownerNpub": key[1] if key else "",
        "localCommunityUrl": local_url,
        "communityMode": stored_mode,
        "communityUrl": relay_url,
        "relayReady": bool(key) and bool(relay_url) and stats["relayReady"],
        "relayState": state,
        "resetting": bool(reset_id),
        "resetRequestId": reset_id,
        "lastResetId": read_first_line(RESET_COMPLETED_FILE),
        "resetError": read_first_line(RESET_ERROR_FILE),
        "restarting": bool(restart_id),
        "restartRequestId": restart_id,
        "lastRestartId": read_first_line(RESTART_COMPLETED_FILE),
        "operations": stats,
        "backup": backup_status_payload(),
    }


def apply_configuration(payload: dict[str, object]) -> tuple[int, dict[str, object]]:
    public_hex, npub, raw_hex = parse_public_key(payload.get("ownerKey"))
    if raw_hex and payload.get("confirmPublicHex") is not True:
        raise InputError(
            "A raw 64-character hex value can be either public or private material. Confirm that this value is a public key."
        )
    community_mode, relay_url = select_community_url(payload)
    media_url, cors_origins = derive_runtime_urls(relay_url)

    with WRITE_LOCK:
        if read_first_line(BACKUP_REQUEST_FILE):
            return HTTPStatus.CONFLICT, {
                "error": "Wait for the current backup to finish before changing configuration."
            }
        existing = current_key()
        existing_hex = existing[0] if existing else ""
        existing_relay_url = read_first_line(RELAY_URL_FILE)
        if existing_hex and existing_relay_url and existing_relay_url != relay_url:
            return HTTPStatus.CONFLICT, {
                "error": (
                    "The canonical Community URL is fixed after initialization. "
                    "A different URL is a different Buzz community and requires a future "
                    "explicit backup-and-reset workflow. No data was changed."
                ),
                "requiresNewCommunityReset": True,
                "currentCommunityUrl": existing_relay_url,
            }
        network_changed = any(
            (
                existing_relay_url != relay_url,
                read_first_line(MEDIA_URL_FILE) != media_url,
                read_first_line(CORS_FILE) != cors_origins,
                read_first_line(COMMUNITY_MODE_FILE) != community_mode,
            )
        )

        if existing_hex and existing_hex != public_hex:
            if payload.get("confirmReset") is not True or payload.get("resetPhrase") != "RESET":
                return HTTPStatus.CONFLICT, {
                    "error": "Changing the owner requires a full data reset and the exact RESET confirmation.",
                    "requiresReset": True,
                }
            if read_first_line(RESET_REQUEST_FILE):
                return HTTPStatus.CONFLICT, {"error": "A data reset is already in progress."}
            request_id = uuid.uuid4().hex
            atomic_write(PENDING_OWNER_FILE, public_hex)
            atomic_write(RELAY_URL_FILE, relay_url)
            atomic_write(MEDIA_URL_FILE, media_url)
            atomic_write(CORS_FILE, cors_origins)
            atomic_write(COMMUNITY_MODE_FILE, community_mode)
            RESET_ERROR_FILE.unlink(missing_ok=True)
            atomic_write(RESET_REQUEST_FILE, request_id)
            return HTTPStatus.ACCEPTED, {
                "message": "Full application data reset started.",
                "resetRequestId": request_id,
                "ownerHex": public_hex,
                "ownerNpub": npub,
                "communityUrl": relay_url,
            }

        atomic_write(RELAY_URL_FILE, relay_url)
        atomic_write(MEDIA_URL_FILE, media_url)
        atomic_write(CORS_FILE, cors_origins)
        atomic_write(COMMUNITY_MODE_FILE, community_mode)

        if not existing_hex:
            atomic_write(OWNER_FILE, public_hex)
            return HTTPStatus.ACCEPTED, {
                "message": "Configuration saved. Current startup status is shown above.",
                "ownerHex": public_hex,
                "ownerNpub": npub,
                "communityUrl": relay_url,
            }

        if network_changed:
            request_id = uuid.uuid4().hex
            atomic_write(RESTART_REQUEST_FILE, request_id)
            return HTTPStatus.ACCEPTED, {
                "message": "Network settings saved. Current restart status is shown above.",
                "restartRequestId": request_id,
                "ownerHex": public_hex,
                "ownerNpub": npub,
                "communityUrl": relay_url,
            }

        return HTTPStatus.OK, {
            "message": "Configuration is already current.",
            "ownerHex": public_hex,
            "ownerNpub": npub,
            "communityUrl": relay_url,
        }


class SetupHandler(BaseHTTPRequestHandler):
    server_version = "BuzzSetup/1.0"

    def log_message(self, format_string: str, *args: object) -> None:
        print(f"[buzz-setup] {self.address_string()} {format_string % args}", flush=True)

    def security_headers(self, content_type: str) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.security_headers("application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_backup_archive(self) -> None:
        path = latest_backup_path()
        if path is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "No backup archive is available."})
            return
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except OSError:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Backup archive is unavailable."})
            return
        with os.fdopen(descriptor, "rb") as handle:
            metadata = os.fstat(handle.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "Backup archive is invalid."})
                return
            self.send_response(HTTPStatus.OK)
            self.security_headers("application/x-tar")
            self.send_header("Content-Disposition", f'attachment; filename="{path.name}"')
            self.send_header("Content-Length", str(metadata.st_size))
            self.end_headers()
            while True:
                chunk = handle.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/api/status":
            self.send_json(HTTPStatus.OK, status_payload())
            return
        if self.path == "/api/backups/download":
            self.send_backup_archive()
            return
        static_files = {
            "/": "index.html",
            "/index.html": "index.html",
            "/app.js": "app.js",
            "/styles.css": "styles.css",
        }
        filename = static_files.get(self.path)
        if not filename:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        path = STATIC_DIR / filename
        try:
            body = path.read_bytes()
        except FileNotFoundError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.security_headers(f"{content_type}; charset=utf-8")
        self.send_header("ETag", hashlib.sha256(body).hexdigest())
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        if self.headers.get("X-Buzz-Setup") != "1":
            self.send_json(HTTPStatus.FORBIDDEN, {"error": "Missing local setup request header."})
            return
        if self.headers.get_content_type() != "application/json":
            self.send_json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "Use application/json."})
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = 0
        if content_length <= 0 or content_length > 16384:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "Invalid request size."})
            return
        try:
            payload = json.loads(self.rfile.read(content_length))
            if not isinstance(payload, dict):
                raise InputError("Request body must be an object.")
            if self.path == "/api/preview-key":
                public_hex, npub, raw_hex = parse_public_key(payload.get("ownerKey"))
                self.send_json(
                    HTTPStatus.OK,
                    {"ownerHex": public_hex, "ownerNpub": npub, "rawHex": raw_hex},
                )
                return
            if self.path == "/api/apply":
                status, response = apply_configuration(payload)
                self.send_json(status, response)
                return
            if self.path == "/api/backups":
                status, response = request_backup(payload)
                self.send_json(status, response)
                return
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Not found."})
        except (json.JSONDecodeError, InputError) as exc:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})


def main() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", 8080), SetupHandler)
    print("[buzz-setup] listening on 0.0.0.0:8080", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
