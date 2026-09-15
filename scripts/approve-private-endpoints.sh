#!/usr/bin/env bash
set -euo pipefail

# Azure CLI performs ARM authentication without exposing bearer tokens or changing
# the selected subscription. Python supplies bounded polling and JSON handling.
# Stable writable schemas (privateEndpoint/provisioningState are not replayed):
# https://github.com/Azure/azure-rest-api-specs/blob/main/specification/network/resource-manager/Microsoft.Network/Network/stable/2024-05-01/applicationGateway.json
# https://github.com/Azure/azure-rest-api-specs/blob/main/specification/app/resource-manager/Microsoft.App/ContainerApps/stable/2025-07-01/ManagedEnvironments.json
exec python3 - <<'PY'
import json
import math
import os
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit


def fail(message):
    raise RuntimeError(message)


class RetryableArmError(Exception):
    pass


def main():
    required = ("TARGET_ID", "TARGET_KIND", "REQUEST_MESSAGE", "SUBSCRIPTION_ID", "TENANT_ID")
    if any(not os.environ.get(key) for key in required):
        fail("Set TARGET_ID, TARGET_KIND, REQUEST_MESSAGE, SUBSCRIPTION_ID and TENANT_ID.")
    target, kind, message, subscription, tenant = (os.environ[key] for key in required)
    versions = {"appgw": "2024-05-01", "aca": "2025-07-01"}
    providers = {"appgw": "Microsoft.Network/applicationGateways", "aca": "Microsoft.App/managedEnvironments"}
    if kind not in versions:
        fail("TARGET_KIND must be appgw or aca.")
    pattern = rf"/subscriptions/{re.escape(subscription)}/resourceGroups/[^/]+/providers/{providers[kind]}/[^/]+"
    if not re.fullmatch(pattern, target, re.IGNORECASE) or any(c in target for c in "?#"):
        fail("TARGET_ID does not match the expected subscription and resource type.")
    timeout = int(os.environ.get("APPROVAL_TIMEOUT_SECONDS", "900"))
    interval = float(os.environ.get("APPROVAL_POLL_SECONDS", "10"))
    if not 1 <= timeout <= 7200 or not math.isfinite(interval) or not 0 < interval <= 120:
        fail("Approval timeout must be 1..7200 seconds and polling interval >0..120 seconds.")
    deadline = time.monotonic() + timeout

    def az(args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            fail("Timed out waiting for the expected Front Door private endpoint approval.")
        try:
            result = subprocess.run(
                ["az", *args, "--only-show-errors", "--output", "json"],
                capture_output=True, text=True, timeout=min(60, remaining),
            )
        except subprocess.TimeoutExpired:
            if args[0] == "rest":
                raise RetryableArmError("Azure CLI request timeout") from None
            fail("Timed out calling Azure CLI while waiting for the expected Front Door private endpoint; inspect ARM connection status and retry.")
        if result.returncode:
            # Do not echo request bodies, credentials or arbitrary Azure responses.
            code = re.search(r"\(([A-Za-z][A-Za-z0-9]+)\)", result.stderr)
            detail = code.group(1) if code else f"exit {result.returncode}"
            retryable_codes = {
                "NotFound", "ResourceNotFound", "ParentResourceNotFound", "ResourceGroupNotFound",
                "TooManyRequests", "AnotherOperationInProgress", "OperationInProgress",
                "Conflict", "InternalServerError", "BadGateway", "ServiceUnavailable",
                "GatewayTimeout", "RetryableError", "RetryableErrorDueToAnotherOperation",
            }
            status = re.search(r"\b(?:HTTP|status(?:\s+code)?)[ :]+(404|409|429|500|502|503|504)\b", result.stderr, re.IGNORECASE)
            if args[0] == "rest" and (detail in retryable_codes or status):
                raise RetryableArmError(detail if code else f"HTTP {status.group(1)}")
            fail(f"Azure CLI {args[0]} failed ({detail}); verify login, tenant, subscription and privateEndpointConnections read/write RBAC.")
        response = json.loads(result.stdout) if result.stdout.strip() else {}
        if not isinstance(response, dict):
            fail("Azure CLI returned an invalid JSON object.")
        return response

    def arm(args):
        while time.monotonic() < deadline:
            try:
                return az(["rest", *args])
            except RetryableArmError as error:
                print(f"ARM is not ready ({error}); retrying within the approval deadline.", file=sys.stderr)
                time.sleep(min(interval, max(0, deadline - time.monotonic())))
        fail("Timed out retrying ARM private endpoint requests; inspect the target and connection state.")

    account = az(["account", "show", "--subscription", subscription])
    if account.get("tenantId", "").lower() != tenant.lower() or account.get("id", "").lower() != subscription.lower():
        fail("Azure CLI account does not match the configured tenant/subscription; no changes made.")

    base = f"https://management.azure.com{target}/privateEndpointConnections"
    list_url = f"{base}?api-version={versions[kind]}"
    stable = 0
    previous_ids = set()
    submitted = set()
    while time.monotonic() < deadline:
        connections = []
        url = list_url
        pages = set()
        while url:
            if not isinstance(url, str):
                fail("Unexpected private endpoint pagination URL type.")
            parsed = urlsplit(url)
            if parsed.scheme != "https" or parsed.netloc != "management.azure.com" or parsed.path.lower() != urlsplit(base).path.lower():
                fail("Unexpected private endpoint pagination URL; refusing to follow it.")
            if url in pages:
                fail("Repeated private endpoint pagination URL.")
            pages.add(url)
            page = arm(["--method", "GET", "--url", url, "--subscription", subscription])
            if not isinstance(page.get("value"), list):
                fail("ARM returned an invalid private endpoint connection list.")
            connections.extend(page["value"])
            url = page.get("nextLink")

        matching = []
        for connection in connections:
            if not isinstance(connection, dict):
                fail("ARM returned a malformed private endpoint connection.")
            properties = connection.get("properties", {})
            if not isinstance(properties, dict):
                fail("ARM returned malformed private endpoint properties.")
            state = properties.get("privateLinkServiceConnectionState", {})
            if not isinstance(state, dict):
                fail("ARM returned a malformed private endpoint connection state.")
            if state.get("description") != message:
                continue
            connection_id = connection.get("id", "")
            prefix = f"{target}/privateEndpointConnections/"
            if not connection_id.lower().startswith(prefix.lower()) or not re.fullmatch(r"[^/?#]+", connection_id[len(prefix):]):
                fail("Matching connection has an unexpected resource ID; refusing approval.")
            status = state.get("status")
            if status not in ("Pending", "Approved"):
                fail(f"Expected Front Door connection is {status}; recreate the origin or investigate the rejected/disconnected connection.")
            matching.append((connection_id, status))
            if status == "Pending" and connection_id not in submitted:
                # Both stable APIs accept the writable connection-state object.
                # Preserve the distinctive request description for idempotent reruns.
                body = {"properties": {"privateLinkServiceConnectionState": {
                    "status": "Approved", "description": message, "actionsRequired": "None",
                }}}
                arm(["--method", "PUT", "--url",
                    f"https://management.azure.com{connection_id}?api-version={versions[kind]}",
                    "--subscription", subscription, "--body", json.dumps(body)])
                submitted.add(connection_id)
                print(f"Submitted approval for expected {kind} Front Door connection.", flush=True)
        ids = {item[0] for item in matching}
        approved = bool(matching) and all(item[1] == "Approved" for item in matching)
        stable = stable + 1 if approved and ids == previous_ids else 0
        previous_ids = ids
        # AFD can create duplicate requests. Require two unchanged approved polls.
        if stable >= 2:
            print(f"Verified {len(ids)} expected {kind} connection(s) approved.")
            return
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
    fail("Timed out waiting for matching Front Door connections to become Approved; check the origin's request message and ARM connection status.")


try:
    main()
except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
    print(f"Private endpoint approval failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
