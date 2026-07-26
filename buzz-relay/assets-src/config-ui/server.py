#!/usr/bin/env python3
"""Local configuration UI for the Umbrel Buzz relay package."""

from __future__ import annotations

import hashlib
import http.client
import json
import mimetypes
import os
import re
import tempfile
import threading
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


CONFIG_DIR = Path(os.environ.get("BUZZ_CONFIG_DIR", "/config"))
STATIC_DIR = Path(os.environ.get("BUZZ_SETUP_STATIC_DIR", "/app/static"))
RELAY_HEALTH_HOST = os.environ.get("BUZZ_RELAY_HEALTH_HOST", "buzz-relay_relay_1")
RELAY_HEALTH_PORT = int(os.environ.get("BUZZ_RELAY_HEALTH_PORT", "8080"))
DEFAULT_RELAY_URL = os.environ.get("BUZZ_DEFAULT_RELAY_URL", "")

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

HEX_KEY_RE = re.compile(r"^[0-9a-fA-F]{64}$")
BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
BECH32_LOOKUP = {char: index for index, char in enumerate(BECH32_CHARSET)}
WRITE_LOCK = threading.Lock()
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


def relay_is_ready() -> bool:
    connection: http.client.HTTPConnection | None = None
    try:
        connection = http.client.HTTPConnection(
            RELAY_HEALTH_HOST, RELAY_HEALTH_PORT, timeout=0.75
        )
        connection.request("GET", "/_readiness")
        return connection.getresponse().status == HTTPStatus.OK
    except (OSError, http.client.HTTPException):
        return False
    finally:
        if connection:
            connection.close()


def current_key() -> tuple[str, str] | None:
    value = read_first_line(OWNER_FILE)
    try:
        public_hex, npub, _ = parse_public_key(value)
        return public_hex, npub
    except InputError:
        return None


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
    return {
        "configured": key is not None and bool(relay_url),
        "ownerConfigured": key is not None,
        "ownerHex": key[0] if key else "",
        "ownerNpub": key[1] if key else "",
        "localCommunityUrl": local_url,
        "communityMode": stored_mode,
        "communityUrl": relay_url,
        "relayReady": bool(key) and bool(relay_url) and relay_is_ready(),
        "relayState": state,
        "resetting": bool(reset_id),
        "resetRequestId": reset_id,
        "lastResetId": read_first_line(RESET_COMPLETED_FILE),
        "resetError": read_first_line(RESET_ERROR_FILE),
        "restarting": bool(restart_id),
        "restartRequestId": restart_id,
        "lastRestartId": read_first_line(RESTART_COMPLETED_FILE),
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
        existing = current_key()
        existing_hex = existing[0] if existing else ""
        network_changed = any(
            (
                read_first_line(RELAY_URL_FILE) != relay_url,
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

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/api/status":
            self.send_json(HTTPStatus.OK, status_payload())
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
