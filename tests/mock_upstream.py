"""Mock OpenAI-compatible upstream for token-saver tests.

Serves POST */chat/completions with a canned reply (SSE stream when the
request asks for stream=true, JSON otherwise) and appends one JSON line per
request (path, auth header, body) to the log file, so tests can assert what
actually reached the "provider" after passing through mitmproxy + headroom.

Usage: python3 mock_upstream.py PORT LOGFILE
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER = "TOKEN_SAVER_MOCK_REPLY_7391"
_log_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet
        pass

    def do_GET(self):
        body = json.dumps({"object": "list", "data": []}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"_raw": raw.decode("utf-8", "replace")}

        with _log_lock, open(sys.argv[2], "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("Authorization", ""),
                "host": self.headers.get("Host", ""),
                "body": body,
            }) + "\n")

        if not self.path.rstrip("/").endswith("chat/completions"):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        model = body.get("model", "mock-1") if isinstance(body, dict) else "mock-1"
        if isinstance(body, dict) and body.get("stream"):
            self._respond_stream(model)
        else:
            self._respond_json(model)

    def _respond_json(self, model):
        payload = json.dumps({
            "id": "chatcmpl-mock", "object": "chat.completion", "created": 1,
            "model": model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": MARKER}}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _respond_stream(self, model):
        def chunk(delta, finish=None):
            return ("data: " + json.dumps({
                "id": "chatcmpl-mock", "object": "chat.completion.chunk",
                "created": 1, "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }) + "\n\n").encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def write_chunk(data):
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")

        write_chunk(chunk({"role": "assistant", "content": ""}))
        write_chunk(chunk({"content": MARKER}))
        write_chunk(chunk({}, finish="stop"))
        write_chunk(b"data: [DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")


if __name__ == "__main__":
    port = int(sys.argv[1])
    open(sys.argv[2], "w").close()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"mock upstream listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()
