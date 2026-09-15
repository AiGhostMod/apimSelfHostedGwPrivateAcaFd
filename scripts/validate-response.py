#!/usr/bin/env python3
"""Validate Terraform endpoint outputs and the mock API response contract."""

import json
import re
import sys
from urllib.parse import urlsplit


def reject_constant(value):
    raise ValueError(f"Non-JSON numeric constant: {value}")


def endpoint_urls(filename):
    with open(filename, encoding="utf-8") as stream:
        outputs = json.load(stream, parse_constant=reject_constant)
    urls = []
    for name in ("self_hosted_endpoint_url", "managed_endpoint_url"):
        item = outputs.get(name)
        value = item.get("value") if isinstance(item, dict) else None
        if not isinstance(value, str) or any(ord(c) <= 32 for c in value):
            raise ValueError(f"{name} must be a nonempty HTTPS Front Door root URL")
        parsed = urlsplit(value)
        if (
            parsed.scheme != "https"
            or len(parsed.netloc) > 253
            or not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+azurefd\.net", parsed.netloc)
            or parsed.path not in ("", "/")
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(f"{name} must be an HTTPS *.azurefd.net root URL without credentials or port")
        urls.append(value.rstrip("/"))
    if urls[0] == urls[1]:
        raise ValueError("Managed and self-hosted Front Door endpoints must be distinct")
    return urls


def validate_response(filename, method, path, payload=None):
    with open(filename, encoding="utf-8") as stream:
        response = json.load(stream, parse_constant=reject_constant)
    if not isinstance(response, dict):
        raise ValueError("Response must be a JSON object")
    for key, expected in (("service", "mock-api"), ("method", method), ("path", path)):
        if response.get(key) != expected:
            raise ValueError(f"Response field {key!r} does not match {expected!r}")
    if payload is not None:
        if "json" not in response:
            raise ValueError("Response is missing the json echo field")
        # Canonical JSON also distinguishes booleans from integers, unlike Python ==.
        expected = json.dumps(json.loads(payload), sort_keys=True)
        actual = json.dumps(response.get("json"), sort_keys=True)
        if actual != expected:
            raise ValueError("Response json field does not exactly echo the POST payload")


def main():
    try:
        if sys.argv[1] == "outputs" and len(sys.argv) == 3:
            print("\n".join(endpoint_urls(sys.argv[2])))
        elif sys.argv[1] == "response" and len(sys.argv) in (5, 6):
            validate_response(*sys.argv[2:])
        else:
            raise ValueError("Invalid validator arguments")
    except (ValueError, OSError, TypeError, IndexError, AttributeError) as error:
        print(f"Validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
