import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "approve-private-endpoints.sh"
SUBSCRIPTION = "11111111-1111-1111-1111-111111111111"
TENANT = "22222222-2222-2222-2222-222222222222"

FAKE_AZ = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ["FAKE_ROOT"])
with (root / "calls").open("a") as f:
    f.write(json.dumps(args) + "\n")
if args[:2] == ["account", "show"]:
    print(json.dumps({"id": os.environ["SUBSCRIPTION_ID"], "tenantId": os.environ.get("FAKE_TENANT", os.environ["TENANT_ID"])}))
    sys.exit()
if os.environ.get("FAKE_ERROR"):
    print("ERROR: (AuthorizationFailed) permission denied", file=sys.stderr)
    sys.exit(1)
method = args[args.index("--method") + 1]
if os.environ.get("FAKE_TRANSIENT_CODE") and method == os.environ.get("FAKE_TRANSIENT_METHOD", "GET"):
    counter = root / "transient"
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n + 1))
    if n < int(os.environ.get("FAKE_TRANSIENT_COUNT", "2")):
        print("ERROR: (" + os.environ["FAKE_TRANSIENT_CODE"] + ") not ready", file=sys.stderr)
        sys.exit(1)
if os.environ.get("FAKE_JSON_LIST"):
    print("[]")
    sys.exit()
if method == "PUT":
    body = json.loads(args[args.index("--body") + 1])
    assert body == {"properties": {"privateLinkServiceConnectionState": {
        "status": "Approved", "description": os.environ["REQUEST_MESSAGE"], "actionsRequired": "None"}}}
    with (root / "approved").open("a") as f:
        f.write(args[args.index("--url") + 1].split("?")[0].rsplit("/", 1)[1] + "\n")
    print("{}")
else:
    counter = root / "counter"
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n + 1))
    pages = json.loads((root / "pages").read_text())
    page = pages[min(n, len(pages) - 1)]
    approved = (root / "approved").read_text().splitlines() if (root / "approved").exists() else []
    for c in page.get("value", []):
        if c["id"].rsplit("/", 1)[1] in approved and not os.environ.get("FAKE_STUCK"):
            c["properties"]["privateLinkServiceConnectionState"]["status"] = "Approved"
    print(json.dumps(page))
"""


class ApprovalTests(unittest.TestCase):
    def setUp(self):
        self.root = Path.cwd() / ("approval-test-" + uuid.uuid4().hex)
        self.root.mkdir()
        self.addCleanup(shutil.rmtree, self.root)
        az = self.root / "az"
        az.write_text(FAKE_AZ)
        az.chmod(0o700)
        self.env = dict(
            os.environ,
            PATH=str(self.root) + os.pathsep + os.environ["PATH"],
            FAKE_ROOT=str(self.root),
            TARGET_KIND="appgw",
            SUBSCRIPTION_ID=SUBSCRIPTION,
            TENANT_ID=TENANT,
            TARGET_ID=f"/subscriptions/{SUBSCRIPTION}/resourceGroups/test/providers/Microsoft.Network/applicationGateways/test",
            REQUEST_MESSAGE="unique:afd:managed",
            APPROVAL_TIMEOUT_SECONDS="2",
            APPROVAL_POLL_SECONDS="0.01",
        )

    def connection(self, name="expected", status="Pending", message=None):
        return {
            "id": self.env["TARGET_ID"] + "/privateEndpointConnections/" + name,
            "properties": {"privateLinkServiceConnectionState": {
                "description": message if message is not None else self.env["REQUEST_MESSAGE"],
                "status": status,
            }},
        }

    def run_script(self, pages):
        (self.root / "pages").write_text(json.dumps(pages))
        result = subprocess.run(["bash", str(SCRIPT)], env=self.env, capture_output=True, text=True, timeout=5)
        calls_file = self.root / "calls"
        calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
        self.assertFalse(any(call[:2] == ["account", "set"] for call in calls))
        puts = [call for call in calls if "PUT" in call]
        return result, puts

    def test_async_duplicates_only_exact_message_are_approved(self):
        unrelated = self.connection("unrelated", message="other profile")
        first = {"value": [unrelated, self.connection()]}
        second = {"value": [unrelated, self.connection(), self.connection("duplicate")]}
        result, puts = self.run_script([{"value": []}, first, second])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(puts), 2)
        self.assertTrue(all("2024-05-01" in call[call.index("--url") + 1] for call in puts))

    def test_approved_is_idempotent(self):
        result, puts = self.run_script([{"value": [self.connection(status="Approved")]}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(puts, [])

    def test_aca_uses_stable_api(self):
        self.env["TARGET_KIND"] = "aca"
        self.env["TARGET_ID"] = f"/subscriptions/{SUBSCRIPTION}/resourceGroups/test/providers/Microsoft.App/managedEnvironments/test"
        result, puts = self.run_script([{"value": [self.connection()]}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2025-07-01", puts[0][puts[0].index("--url") + 1])

    def test_wrong_tenant_never_writes(self):
        self.env["FAKE_TENANT"] = "wrong"
        result, puts = self.run_script([{"value": [self.connection()]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tenant/subscription", result.stderr)
        self.assertEqual(puts, [])

    def test_rejected_never_approved(self):
        result, puts = self.run_script([{"value": [self.connection(status="Rejected")]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rejected", result.stderr)
        self.assertEqual(puts, [])

    def test_timeout_without_expected_request(self):
        self.env["APPROVAL_TIMEOUT_SECONDS"] = "1"
        result, puts = self.run_script([{"value": [self.connection(message="unrelated")]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timed out", result.stderr)
        self.assertEqual(puts, [])

    def test_pending_after_put_times_out_without_repeated_writes(self):
        self.env.update(FAKE_STUCK="1", APPROVAL_TIMEOUT_SECONDS="1")
        result, puts = self.run_script([{"value": [self.connection()]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(puts), 1)

    def test_unexpected_connection_id_never_written(self):
        connection = self.connection()
        connection["id"] = connection["id"].replace("/applicationGateways/test/", "/applicationGateways/other/")
        result, puts = self.run_script([{"value": [connection]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected resource ID", result.stderr)
        self.assertEqual(puts, [])

    def test_untrusted_pagination_never_followed(self):
        result, puts = self.run_script([{"value": [], "nextLink": "https://example.com/stolen"}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pagination URL", result.stderr)
        self.assertEqual(puts, [])

    def test_authorization_error_is_actionable(self):
        self.env["FAKE_ERROR"] = "1"
        result, puts = self.run_script([{"value": []}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AuthorizationFailed", result.stderr)
        self.assertIn("RBAC", result.stderr)
        self.assertEqual(puts, [])

    def test_transient_list_errors_are_retried(self):
        self.env["FAKE_TRANSIENT_CODE"] = "ResourceNotFound"
        result, puts = self.run_script([{"value": [self.connection()]}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(puts), 1)
        self.assertIn("retrying", result.stderr)

    def test_idempotent_put_is_retried_after_throttling(self):
        self.env.update(FAKE_TRANSIENT_CODE="TooManyRequests", FAKE_TRANSIENT_METHOD="PUT", FAKE_TRANSIENT_COUNT="1")
        result, puts = self.run_script([{"value": [self.connection()]}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(puts), 2)

    def test_transient_retries_share_the_deadline(self):
        self.env.update(FAKE_TRANSIENT_CODE="ServiceUnavailable", FAKE_TRANSIENT_COUNT="999", APPROVAL_TIMEOUT_SECONDS="1")
        result, puts = self.run_script([{"value": [self.connection()]}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Timed out", result.stderr)
        self.assertEqual(puts, [])

    def test_nonobject_cli_response_fails_clearly(self):
        self.env["FAKE_JSON_LIST"] = "1"
        result, puts = self.run_script([{"value": []}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid JSON object", result.stderr)
        self.assertEqual(puts, [])

    def test_nonfinite_interval_is_rejected_before_azure(self):
        self.env["APPROVAL_POLL_SECONDS"] = "nan"
        result, puts = self.run_script([{"value": []}])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("polling interval", result.stderr)
        self.assertEqual(puts, [])


if __name__ == "__main__":
    unittest.main()
