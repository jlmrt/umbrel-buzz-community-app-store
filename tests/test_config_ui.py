import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "buzz-relay" / "assets-src" / "config-ui" / "server.py"
SPEC = importlib.util.spec_from_file_location("buzz_setup_server", MODULE_PATH)
assert SPEC and SPEC.loader
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class PublicKeyTests(unittest.TestCase):
    def test_hex_and_npub_round_trip(self) -> None:
        public_hex = "12" * 32
        normalized_hex, npub, raw_hex = server.parse_public_key(public_hex.upper())
        self.assertEqual(normalized_hex, public_hex)
        self.assertTrue(raw_hex)
        decoded_hex, normalized_npub, decoded_raw_hex = server.parse_public_key(npub)
        self.assertEqual(decoded_hex, public_hex)
        self.assertEqual(normalized_npub, npub)
        self.assertFalse(decoded_raw_hex)

    def test_rejects_nsec(self) -> None:
        nsec = server.bech32_encode("nsec", bytes.fromhex("34" * 32))
        with self.assertRaisesRegex(server.InputError, "Private keys"):
            server.parse_public_key(nsec)
        with self.assertRaisesRegex(server.InputError, "Private keys"):
            server.parse_public_key(f"nostr:{nsec}")

    def test_rejects_bad_npub_checksum(self) -> None:
        npub = server.bech32_encode("npub", bytes.fromhex("56" * 32))
        replacement = "q" if npub[-1] != "q" else "p"
        with self.assertRaisesRegex(server.InputError, "checksum"):
            server.parse_public_key(npub[:-1] + replacement)


class ConfigurationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        config_dir = Path(self.temporary.name)
        paths = {
            "CONFIG_DIR": config_dir,
            "OWNER_FILE": config_dir / "relay-owner-pubkey",
            "PENDING_OWNER_FILE": config_dir / "pending-owner-pubkey",
            "RELAY_URL_FILE": config_dir / "relay-url",
            "MEDIA_URL_FILE": config_dir / "media-base-url",
            "CORS_FILE": config_dir / "cors-origins",
            "RESET_REQUEST_FILE": config_dir / "reset-request",
            "RESET_COMPLETED_FILE": config_dir / "reset-completed",
            "RESET_ERROR_FILE": config_dir / "reset-error",
            "RESTART_REQUEST_FILE": config_dir / "restart-request",
            "RESTART_COMPLETED_FILE": config_dir / "restart-completed",
            "RELAY_STATE_FILE": config_dir / "relay-state",
        }
        self.originals = {name: getattr(server, name) for name in paths}
        for name, value in paths.items():
            setattr(server, name, value)

    def tearDown(self) -> None:
        for name, value in self.originals.items():
            setattr(server, name, value)
        self.temporary.cleanup()

    @staticmethod
    def payload(owner_key: str) -> dict[str, object]:
        return {
            "ownerKey": owner_key,
            "confirmPublicHex": True,
            "relayUrl": "wss://buzz.example.com",
            "mediaBaseUrl": "https://buzz.example.com/media",
            "corsOrigins": "https://buzz.example.com,tauri://localhost",
            "confirmReset": False,
            "resetPhrase": "",
        }

    def test_raw_hex_requires_public_key_confirmation(self) -> None:
        payload = self.payload("12" * 32)
        payload["confirmPublicHex"] = False
        with self.assertRaisesRegex(server.InputError, "public key"):
            server.apply_configuration(payload)

    def test_initial_configuration_saves_normalized_public_key(self) -> None:
        status, _ = server.apply_configuration(self.payload("AB" * 32))
        self.assertEqual(status, 202)
        self.assertEqual(server.OWNER_FILE.read_text().strip(), "ab" * 32)
        self.assertNotIn("nsec", server.OWNER_FILE.read_text())
        self.assertFalse(server.RESET_REQUEST_FILE.exists())

    def test_owner_change_requires_and_schedules_full_reset(self) -> None:
        server.apply_configuration(self.payload("12" * 32))
        status, response = server.apply_configuration(self.payload("34" * 32))
        self.assertEqual(status, 409)
        self.assertTrue(response["requiresReset"])

        payload = self.payload("34" * 32)
        payload["confirmReset"] = True
        payload["resetPhrase"] = "RESET"
        status, _ = server.apply_configuration(payload)
        self.assertEqual(status, 202)
        self.assertEqual(server.OWNER_FILE.read_text().strip(), "12" * 32)
        self.assertEqual(server.PENDING_OWNER_FILE.read_text().strip(), "34" * 32)
        self.assertTrue(server.RESET_REQUEST_FILE.read_text().strip())

    def test_rejects_non_websocket_relay_url(self) -> None:
        payload = self.payload("12" * 32)
        payload["relayUrl"] = "https://buzz.example.com"
        with self.assertRaisesRegex(server.InputError, "ws:// or wss://"):
            server.apply_configuration(payload)


if __name__ == "__main__":
    unittest.main()
