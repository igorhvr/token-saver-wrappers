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

        path = self.path.split("?", 1)[0].rstrip("/")
        model = body.get("model", "mock-1") if isinstance(body, dict) else "mock-1"
        stream = bool(isinstance(body, dict) and body.get("stream"))
        if path.endswith("chat/completions"):
            self._respond_stream(model) if stream else self._respond_json(model)
        elif path.endswith("/messages"):            # Anthropic Messages API (Claude)
            self._respond_anthropic(model, stream)
        elif path.endswith("/responses"):           # OpenAI Responses API (Codex)
            self._respond_responses(model, stream)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

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

    # --- Anthropic Messages API (Claude Code) --------------------------------
    def _respond_anthropic(self, model, stream):
        if not stream:
            payload = json.dumps({
                "id": "msg_mock", "type": "message", "role": "assistant",
                "model": model,
                "content": [{"type": "text", "text": MARKER}],
                "stop_reason": "end_turn", "stop_sequence": None,
                "usage": {"input_tokens": 5, "output_tokens": 5},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def ev(event, data):
            body = f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()
            self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n")

        ev("message_start", {"type": "message_start", "message": {
            "id": "msg_mock", "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 5, "output_tokens": 1}}})
        ev("content_block_start", {"type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""}})
        ev("content_block_delta", {"type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": MARKER}})
        ev("content_block_stop", {"type": "content_block_stop", "index": 0})
        ev("message_delta", {"type": "message_delta",
            "delta": {"stop_reason": "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 5}})
        ev("message_stop", {"type": "message_stop"})
        self.wfile.write(b"0\r\n\r\n")

    # --- OpenAI Responses API (Codex) ----------------------------------------
    def _respond_responses(self, model, stream):
        msg = {"type": "message", "role": "assistant",
               "content": [{"type": "output_text", "text": MARKER}]}
        completed = {"id": "resp_mock", "object": "response", "model": model,
                     "status": "completed", "output": [msg],
                     "usage": {"input_tokens": 5, "output_tokens": 5, "total_tokens": 10}}
        if not stream:
            payload = json.dumps(completed).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def ev(event, data):
            body = f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()
            self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n")

        item = {"id": "msg_1", "type": "message", "role": "assistant", "content": []}
        ev("response.created", {"type": "response.created",
            "response": {"id": "resp_mock", "object": "response", "status": "in_progress"}})
        # Item lifecycle: codex rejects an output_text delta with no active item.
        ev("response.output_item.added", {"type": "response.output_item.added",
            "output_index": 0, "item": item})
        ev("response.content_part.added", {"type": "response.content_part.added",
            "item_id": "msg_1", "output_index": 0, "content_index": 0,
            "part": {"type": "output_text", "text": ""}})
        ev("response.output_text.delta", {"type": "response.output_text.delta",
            "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": MARKER})
        ev("response.output_text.done", {"type": "response.output_text.done",
            "item_id": "msg_1", "output_index": 0, "content_index": 0, "text": MARKER})
        ev("response.content_part.done", {"type": "response.content_part.done",
            "item_id": "msg_1", "output_index": 0, "content_index": 0,
            "part": {"type": "output_text", "text": MARKER}})
        done_item = {"id": "msg_1", "type": "message", "role": "assistant",
                     "content": [{"type": "output_text", "text": MARKER}]}
        ev("response.output_item.done", {"type": "response.output_item.done",
            "output_index": 0, "item": done_item})
        ev("response.completed", {"type": "response.completed", "response": completed})
        self.wfile.write(b"0\r\n\r\n")


if __name__ == "__main__":
    port = int(sys.argv[1])
    open(sys.argv[2], "w").close()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"mock upstream listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()
