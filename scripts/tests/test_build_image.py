"""Offline image-build tests; PATH contains only fixture commands, never real az."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-image.sh"
BASH = shutil.which("bash")
SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
TAG = "a" * 64
FAKE_AZ = r"""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path(os.environ["FAKE_CALLS"]).open("a") as calls:
    calls.write(json.dumps(args) + "\n")
if args[:2] == ["account", "show"]:
    sys.exit(int(os.environ.get("FAKE_ACCOUNT_EXIT", "0")))
if args[:2] != ["acr", "build"]:
    sys.exit("Unexpected Azure CLI command")
context = Path(args[-1])
dockerfile = Path(args[args.index("--file") + 1])
assert context.is_absolute() and context.is_dir(), context
assert dockerfile.is_absolute() and dockerfile.is_file(), dockerfile
assert dockerfile == context / "Dockerfile", (dockerfile, context)
for name in ("requirements.txt", ".dockerignore", "app/main.py"):
    assert (context / name).is_file(), name
sys.exit(int(os.environ.get("FAKE_BUILD_EXIT", "0")))
"""


class BuildImageTests(unittest.TestCase):
    def setUp(self):
        self.workspace = ROOT / ("build-image-test-" + uuid.uuid4().hex)
        self.workspace.mkdir()
        self.addCleanup(shutil.rmtree, self.workspace)
        self.bin = self.workspace / "bin"
        self.bin.mkdir()
        self.az = self.bin / "az"
        self.az.write_text(f"#!{sys.executable}\n" + FAKE_AZ)
        self.az.chmod(0o700)
        (self.bin / "dirname").symlink_to(shutil.which("dirname"))
        self.cwd = self.workspace / "unrelated working directory"
        self.cwd.mkdir()
        self.calls_file = self.workspace / "calls.jsonl"
        self.env = {
            "PATH": str(self.bin),
            "FAKE_CALLS": str(self.calls_file),
            "AZURE_SUBSCRIPTION_ID": SUBSCRIPTION,
            "ACR_NAME": "testregistry123",
            "IMAGE_TAG": TAG,
        }

    def run_script(self, script=SCRIPT, cwd=None):
        self.calls_file.unlink(missing_ok=True)
        result = subprocess.run(
            [BASH, str(script)], cwd=cwd or self.cwd, env=self.env,
            capture_output=True, text=True, timeout=10,
        )
        calls = (
            [json.loads(line) for line in self.calls_file.read_text().splitlines()]
            if self.calls_file.exists() else []
        )
        return result, calls

    def assert_build(self, result, calls, project):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["account", "show", "--subscription", SUBSCRIPTION, "--output", "none"],
            [
                "acr", "build", "--subscription", SUBSCRIPTION,
                "--registry", "testregistry123", "--image", f"mock-api:{TAG}",
                "--platform", "linux/amd64",
                "--file", str(project / "mock-api/Dockerfile"), "--no-logs",
                str(project / "mock-api"),
            ],
        ])

    def test_build_from_project_and_unrelated_directory(self):
        for cwd in (ROOT, self.cwd):
            with self.subTest(cwd=cwd):
                result, calls = self.run_script(cwd=cwd)
                self.assert_build(result, calls, ROOT)

    def test_project_path_with_spaces_and_relative_script_invocation(self):
        project = self.workspace / "project with spaces"
        (project / "scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT, project / "scripts/build-image.sh")
        shutil.copytree(
            ROOT / "mock-api", project / "mock-api",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        script = os.path.relpath(project / "scripts/build-image.sh", self.cwd)
        result, calls = self.run_script(script=script)
        self.assert_build(result, calls, project)

    def test_required_environment_missing_or_empty(self):
        for name in ("AZURE_SUBSCRIPTION_ID", "ACR_NAME", "IMAGE_TAG"):
            for value in (None, ""):
                with self.subTest(name=name, value=value):
                    original = self.env.pop(name)
                    if value is not None:
                        self.env[name] = value
                    try:
                        result, calls = self.run_script()
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(f"Set {name}", result.stderr)
                        self.assertEqual(calls, [])
                    finally:
                        self.env[name] = original

    def test_invalid_environment_never_calls_azure(self):
        for name, value, message in (
            ("AZURE_SUBSCRIPTION_ID", "not-a-uuid", "Invalid Azure subscription ID"),
            ("ACR_NAME", "invalid-registry", "Invalid ACR name"),
            ("IMAGE_TAG", "latest", "SHA-256 build-context hash"),
        ):
            with self.subTest(name=name):
                original = self.env[name]
                self.env[name] = value
                try:
                    result, calls = self.run_script()
                    self.assertEqual(result.returncode, 2)
                    self.assertIn(message, result.stderr)
                    self.assertEqual(calls, [])
                finally:
                    self.env[name] = original

    def test_missing_azure_cli(self):
        self.az.unlink()
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 127)
        self.assertIn("Azure CLI is required", result.stderr)
        self.assertEqual(calls, [])

    def test_account_failure_stops_before_build(self):
        self.env["FAKE_ACCOUNT_EXIT"] = "23"
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 23)
        self.assertEqual(calls, [
            ["account", "show", "--subscription", SUBSCRIPTION, "--output", "none"],
        ])

    def test_build_failure_is_propagated(self):
        self.env["FAKE_BUILD_EXIT"] = "42"
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[-1][:2], ["acr", "build"])


if __name__ == "__main__":
    unittest.main()
