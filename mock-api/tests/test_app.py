import io
import json
import unittest

from app.main import MAX_BODY_BYTES, application


class MockApiTests(unittest.TestCase):
    def request(self, method, path, body=b"", length=None, chunked=False):
        response = {}

        def start_response(status, headers):
            response["status"] = int(status.split()[0])
            response["headers"] = dict(headers)

        encoded = b"".join(application({
            "REQUEST_METHOD": method,
            "PATH_INFO": path,
            "CONTENT_LENGTH": "" if chunked else (str(len(body)) if length is None else length),
            "wsgi.input_terminated": chunked,
            "wsgi.input": io.BytesIO(body),
        }, start_response))
        self.assertEqual(int(response["headers"]["Content-Length"]), len(encoded))
        return response["status"], json.loads(encoded), response["headers"]

    def test_get(self):
        status, body, _ = self.request("GET", "/get")
        self.assertEqual(status, 200)
        self.assertEqual(body, {"method": "GET", "path": "/get", "service": "mock-api"})

    def test_arbitrary_json(self):
        for payload in [None, [], [1, None, {"a": False}], {}, {"nested": ["ą", True]},
                        "string", "", 12, -3.5, True, False]:
            with self.subTest(payload=payload):
                status, body, _ = self.request("POST", "/post", json.dumps(payload).encode())
                self.assertEqual(status, 200)
                self.assertEqual(body, {
                    "method": "POST", "path": "/post", "service": "mock-api", "json": payload,
                })

    def test_invalid_json(self):
        for body in [b"", b"{", b"not json", b"null null", b"\xff", b"NaN", b"Infinity"]:
            with self.subTest(body=body):
                status, payload, _ = self.request("POST", "/post", body)
                self.assertEqual(status, 400)
                self.assertEqual(payload["error"], "invalid JSON")

    def test_large_exponent_is_valid_json(self):
        self.assertEqual(self.request("POST", "/post", b"1e400")[0], 200)

    def test_invalid_length(self):
        for length in ["-1", "abc", "10"]:
            self.assertEqual(self.request("POST", "/post", b"{}", length)[0], 400)

    def test_body_limit(self):
        self.assertEqual(self.request("POST", "/post", length=str(MAX_BODY_BYTES + 1))[0], 413)
        exact = b'"' + b"x" * (MAX_BODY_BYTES - 2) + b'"'
        self.assertEqual(self.request("POST", "/post", exact)[0], 200)
        self.assertEqual(self.request("POST", "/post", exact + b" ")[0], 413)

    def test_chunked_json_and_size_limit(self):
        for payload in (b'{"chunked":true}', b"null", b"[1,2,3]"):
            with self.subTest(payload=payload):
                status, body, _ = self.request("POST", "/post", payload, chunked=True)
                self.assertEqual(status, 200)
                self.assertEqual(body["json"], json.loads(payload))
        self.assertEqual(self.request("POST", "/post", b"x" * (MAX_BODY_BYTES + 1), chunked=True)[0], 413)

    def test_health(self):
        self.assertEqual(self.request("GET", "/health")[:2], (200, {"status": "ok"}))

    def test_methods_and_missing_routes(self):
        for path, allowed in [("/get", "GET"), ("/health", "GET"), ("/post", "POST")]:
            for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]:
                if method == allowed:
                    continue
                with self.subTest(path=path, method=method):
                    status, _, headers = self.request(method, path)
                    self.assertEqual(status, 405)
                    self.assertEqual(headers["Allow"], allowed)
        self.assertEqual(self.request("GET", "/missing")[0], 404)


if __name__ == "__main__":
    unittest.main()
