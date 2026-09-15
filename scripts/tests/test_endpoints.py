"""Offline runner tests: no Azure calls or network access."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test-endpoints.sh"
FAKE_CURL = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert args[0] == "--disable"
def arg(key):
    return args[args.index(key) + 1]
assert "--insecure" not in args and "-k" not in args
assert arg("--proto") == "=https"
assert "--location" not in args
assert arg("--max-time").isdigit()
url = arg("--url")
method = arg("--request")
state = pathlib.Path("calls.json")
calls = json.loads(state.read_text()) if state.exists() else []
previous = sum(c["url"] == url and c["method"] == method for c in calls)
calls.append({"url": url, "method": method})
state.write_text(json.dumps(calls))
mode = os.environ.get("FAKE_MODE", "success")
body = {"service":"mock-api","method":method,"path":"/post" if method == "POST" else "/get"}
if method == "POST":
    body["json"] = json.loads(arg("--data-raw"))
status = "200"
exit_code = 0
if mode == "wrong-schema":
    body["service"] = "wrong"
if mode == "wrong-echo" and method == "POST":
    body["json"]["enabled"] = 1
if mode == "wrong-status":
    status = "503"
if mode == "redirect":
    status = "302"
if mode == "slow" and previous == 0:
    status, exit_code = "000", 28
encoded = json.dumps(body)
if mode == "invalid-json" or (mode == "retry-json" and previous == 0):
    encoded = "<html>not ready</html>"
if mode == "non-json-number":
    encoded = encoded[:-1] + ', "extra": NaN}'
pathlib.Path(arg("--output")).write_text(encoded)
sys.stdout.write(status)
sys.exit(exit_code)
"""


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix=".smoke-unit-", dir=ROOT)
        self.addCleanup(self.workspace.cleanup)
        self.cwd = Path(self.workspace.name)
        self.bin = self.cwd / "bin"
        self.bin.mkdir()
        curl = self.bin / "curl"
        curl.write_text(FAKE_CURL)
        curl.chmod(0o700)
        terraform = self.bin / "terraform"
        terraform.write_text("#!/usr/bin/env python3\nimport pathlib,sys\n"
                             "assert sys.argv[1:] == ['output', '-json']\n"
                             "print(pathlib.Path('outputs.json').read_text())\n")
        terraform.chmod(0o700)
        self.outputs = {
            "self_hosted_endpoint_url": {"value": "https://self-test.azurefd.net"},
            "managed_endpoint_url": {"value": "https://managed-test.azurefd.net/"},
        }
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SMOKE_MAX_ATTEMPTS="2", SMOKE_RETRY_DELAY="0",
                        SMOKE_REQUEST_TIMEOUT="1")

    def run_script(self, mode="success", default=False, **settings):
        (self.cwd / "outputs.json").write_text(json.dumps(self.outputs))
        result = subprocess.run(
            ["bash", str(SCRIPT)] + ([] if default else ["outputs.json"]),
            cwd=self.cwd, env=dict(self.env, FAKE_MODE=mode, **settings),
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(list(self.cwd.glob(".smoke-test-*")), [])
        return result

    def calls(self):
        file = self.cwd / "calls.json"
        return json.loads(file.read_text()) if file.exists() else []

    def test_success(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["method"] for c in self.calls()], ["GET", "POST", "GET"])
        self.assertIn("HTTP=200", result.stdout)
        self.assertIn('"service": "mock-api"', result.stdout)

    def test_default_terraform_output(self):
        self.assertEqual(self.run_script(default=True).returncode, 0)

    def test_generated_multilabel_frontdoor_hosts(self):
        self.outputs = {
            "self_hosted_endpoint_url": {"value": "https://self-test-abc123.z01.azurefd.net"},
            "managed_endpoint_url": {"value": "https://managed-test-def456.z02.azurefd.net/"},
        }
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 3)

    def test_missing_null_echo_is_rejected(self):
        body = self.cwd / "body.json"
        body.write_text(json.dumps({"service": "mock-api", "method": "POST", "path": "/post"}))
        validator = ROOT / "scripts/validate-response.py"
        result = subprocess.run(
            ["python3", "-B", str(validator), "response", str(body), "POST", "/post", "null"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing the json echo", result.stderr)

    def test_retry_invalid_json(self):
        self.assertEqual(self.run_script("retry-json").returncode, 0)
        self.assertEqual(len(self.calls()), 6)

    def test_slow_request_retried(self):
        result = self.run_script("slow")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("curl=28 HTTP=000", result.stdout)
        self.assertEqual(len(self.calls()), 6)

    def test_persistent_failures(self):
        for mode in ("invalid-json", "non-json-number", "wrong-schema", "wrong-echo", "wrong-status", "redirect"):
            with self.subTest(mode=mode):
                result = self.run_script(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("FAIL:", result.stderr)

    def test_missing_outputs(self):
        del self.outputs["managed_endpoint_url"]
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_malformed_outputs(self):
        self.outputs = ["not", "an", "object"]
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_untrusted_urls(self):
        for url in (
            "http://self-test.azurefd.net", "https://localhost", "https://127.0.0.1",
            "https://self-test.azurefd.net@evil.example",
            "https://self-test.azurefd.net.evil.example",
            "https://self-test.azurefd.net/$(touch PWNED)",
            "https://self-test.azurefd.net\n--insecure",
            "https://self-test.azurefd.net?secret=1", "https://self-test.azurefd.net/#x",
            "https://self-test.azurefd.net:443", "--output=PWNED", None, 7,
            "https://bad..z01.azurefd.net", "https://-bad.z01.azurefd.net",
            "https://bad-.z01.azurefd.net", "https://azurefd.net",
            "https://" + "a" * 64 + ".azurefd.net",
        ):
            with self.subTest(url=url):
                self.outputs["self_hosted_endpoint_url"]["value"] = url
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertFalse((self.cwd / "PWNED").exists())

    def test_duplicate_endpoints(self):
        self.outputs["self_hosted_endpoint_url"] = self.outputs["managed_endpoint_url"]
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_retry_settings(self):
        for value in ("0", "-1", "121", "abc", "$(touch PWNED)"):
            with self.subTest(value=value):
                self.assertNotEqual(self.run_script(SMOKE_MAX_ATTEMPTS=value).returncode, 0)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
