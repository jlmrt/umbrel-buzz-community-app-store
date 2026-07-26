import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "check_upstream_buzz.py"
SPEC = importlib.util.spec_from_file_location("upstream_monitor", MODULE_PATH)
assert SPEC and SPEC.loader
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)


class UpstreamMonitorTests(unittest.TestCase):
    def test_package_version_retains_package_revision(self) -> None:
        release = {"tag_name": "v1.2.3"}
        self.assertEqual(monitor.package_version(release, "abcdef0"), "1.2.3-abcdef0-1")
        self.assertEqual(
            monitor.package_version(release, "abcdef0", "1.2.3-abcdef0-4"),
            "1.2.3-abcdef0-4",
        )

    def test_deployment_listing_tracks_every_file(self) -> None:
        entries = [
            {"type": "file", "path": "deploy/compose/README.md"},
            {"type": "file", "path": "deploy/compose/.env.example"},
            {"type": "file", "path": "deploy/compose/compose.yml"},
            {"type": "file", "path": "deploy/compose/new-production-file.yml"},
            {"type": "dir", "path": "deploy/compose/examples"},
        ]
        with mock.patch.object(monitor, "github_api", return_value=entries):
            files = monitor.list_upstream_deploy_files("a" * 40)
        self.assertIn("deploy/compose/new-production-file.yml", files)
        self.assertNotIn("deploy/compose/examples", files)

    def test_missing_core_deployment_file_fails(self) -> None:
        entries = [{"type": "file", "path": "deploy/compose/README.md"}]
        with mock.patch.object(monitor, "github_api", return_value=entries):
            with self.assertRaisesRegex(monitor.UpstreamUnavailable, "missing"):
                monitor.list_upstream_deploy_files("a" * 40)

    def test_missing_expected_image_fails(self) -> None:
        latest_release = {"tag_name": "v1.2.3"}
        argv = ["check_upstream_buzz.py", "--strategy", "default-branch"]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(
                monitor,
                "select_target",
                return_value=("main", "abcdef0123456789", latest_release),
            ), mock.patch.object(monitor, "ghcr_digest", return_value=None):
            with self.assertRaisesRegex(monitor.UpstreamUnavailable, "missing"):
                monitor.main()


if __name__ == "__main__":
    unittest.main()
