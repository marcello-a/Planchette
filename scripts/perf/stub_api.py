"""A stand-in for the Anthropic API, for driving the real Claude Code CLI without a login.

usage: stub_api.py <port> <logfile>
Every request is logged as one JSON line: method, path and, for /v1/messages, the text of the
last user message. Replies are valid (streamed) message responses. Binds to 127.0.0.1 only.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, logfile = int(sys.argv[1]), sys.argv[2]

def log(entry):
    entry["t"] = round(time.time(), 3)
    with open(logfile, "a") as handle:
        handle.write(json.dumps(entry) + "\n")

def last_user_text(body):
    try:
        messages = body.get("messages", [])
        for message in reversed(messages):
            if message.get("role") != "user":
                continue
            content = message.get("content")
            if isinstance(content, str):
                return content
            return " ".join(part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text")
    except Exception as error:
        return f"(unparsed: {error})"
    return ""

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send_json(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        log({"method": "GET", "path": self.path})
        if self.path.startswith("/v1/models"):
            self._send_json(200, {"data": [{"id": "claude-sonnet-4-5", "type": "model", "display_name": "stub"}], "has_more": False})
        else:
            self._send_json(200, {})

    def do_HEAD(self):
        log({"method": "HEAD", "path": self.path})
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        if self.path.startswith("/v1/messages/count_tokens"):
            log({"method": "POST", "path": self.path})
            self._send_json(200, {"input_tokens": 10})
            return
        if not self.path.startswith("/v1/messages"):
            log({"method": "POST", "path": self.path})
            self._send_json(200, {})
            return
        text = last_user_text(body)
        import re
        # What the LAST user message says, whole - and which probe tokens it contains (the first
        # message of a conversation starts with long system reminders, so a prefix is useless).
        log({"method": "POST", "path": self.path, "model": body.get("model"), "stream": body.get("stream"),
             "max_tokens": body.get("max_tokens"), "user_text": text[:400], "user_tail": text[-600:],
             "user_len": len(text), "probes": re.findall(r"[A-Z][A-Z0-9_]{5,}", text[-600:])})
        reply = "STUB-REPLY"
        usage = {"input_tokens": 10, "output_tokens": 3}
        if not body.get("stream"):
            self._send_json(200, {"id": "msg_stub", "type": "message", "role": "assistant", "model": body.get("model", "stub"),
                                  "content": [{"type": "text", "text": reply}], "stop_reason": "end_turn",
                                  "stop_sequence": None, "usage": usage})
            return
        events = [
            ("message_start", {"type": "message_start", "message": {"id": "msg_stub", "type": "message", "role": "assistant",
                               "model": body.get("model", "stub"), "content": [], "stop_reason": None, "stop_sequence": None,
                               "usage": {"input_tokens": 10, "output_tokens": 1}}}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": reply}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 3}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        payload = "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
