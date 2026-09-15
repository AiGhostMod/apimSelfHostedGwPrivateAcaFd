"""Small WSGI JSON echo service, served by Gunicorn in the container."""

import json

MAX_BODY_BYTES = 1024 * 1024


def reject_constant(value):
    raise ValueError(f"Not a JSON value: {value}")


def application(environ, start_response):
    method = environ.get("REQUEST_METHOD", "GET")
    path = environ.get("PATH_INFO", "/")
    headers = []
    echoed_json = None
    expected_method = {"/get": "GET", "/post": "POST", "/health": "GET"}.get(path)
    if expected_method is None:
        status, payload = "404 Not Found", {"error": "not found"}
    elif method != expected_method:
        status, payload = "405 Method Not Allowed", {"error": "method not allowed"}
        headers.append(("Allow", expected_method))
    elif path == "/health":
        status, payload = "200 OK", {"status": "ok"}
    else:
        status = "200 OK"
        payload = {"method": method, "path": path, "service": "mock-api"}
        if method == "POST":
            try:
                content_length = environ.get("CONTENT_LENGTH")
                if content_length:
                    length = int(content_length)
                    if length < 0:
                        raise ValueError("Negative content length")
                    body = b"" if length > MAX_BODY_BYTES else environ["wsgi.input"].read(length)
                    if length <= MAX_BODY_BYTES and len(body) != length:
                        raise ValueError("Incomplete body")
                else:
                    # Gunicorn marks safely terminated streams, including chunked requests.
                    body = environ["wsgi.input"].read(MAX_BODY_BYTES + 1) if environ.get("wsgi.input_terminated") else b""
                    length = len(body)
                if length > MAX_BODY_BYTES:
                    status, payload = "413 Content Too Large", {"error": "JSON body too large"}
                else:
                    text = body.decode("utf-8")
                    json.loads(text, parse_constant=reject_constant)
                    # Preserve valid JSON numbers exactly (including exponents
                    # larger than a Python float) instead of reserializing them.
                    echoed_json = text.encode("utf-8")
            except (ValueError, UnicodeDecodeError, RecursionError):
                status, payload = "400 Bad Request", {"error": "invalid JSON"}
    body = json.dumps(payload, ensure_ascii=True, allow_nan=False).encode("utf-8")
    if echoed_json is not None:
        body = body[:-1] + b', "json": ' + echoed_json + b"}"
    headers.extend([
        ("Content-Type", "application/json"),
        ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"),
    ])
    start_response(status, headers)
    return [body]
