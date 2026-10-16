"""A stand-in for the Anthropic API, for driving the real Claude Code CLI without a login.

usage: stub_api.py <port> <logfile>
Every request is logged as one JSON line: method, path and, for /v1/messages, the text of the
last user message. Replies are valid (streamed) message responses. Binds to 127.0.0.1 only.

Replies are plain text, except when the last user message holds one of these tokens (and the
request is not the small model's title request): the reply is then a tool call, so the real
Claude Code starts real background work without any model behind it (`background_tasks.py`).
  BGSHELL<n>   Bash `sleep <n>` with run_in_background -> a background shell for n seconds
  BGAGENT<n>   Agent (async) whose work -> a background agent that finishes after n seconds
  SUBWORK<n>   the launched agent's own prompt: this reply is held back n seconds
  SLOW<n>      the reply is held back n seconds: a turn that stays "running" (state_sync.py)
  STREAM<n>    the answer starts at once (text on screen) and then stalls for n seconds
  ASKPERM<n>   Bash `touch permtest.txt`: a command that needs a permission, so a dialog opens
  PERMWAIT<n>   Bash `touch permtest.txt; sleep <n>`: a permission dialog, then a tool that goes on for n seconds
  MCPCALL<n>   the tool `slow` of the MCP server `probe` (mcp_probe.py): a tool call that takes n seconds
Each token is answered once (see `answered`); a second task needs a different number.
No token may contain another one: `re.search` finds SLOW inside ASKSLOW, and the held-back reply wins.
"""
import json, re, sys, threading, time
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

# Claude Code does not send a plain transcript: a new prompt arrives in the same user message as the
# result of the previous tool call, and an earlier prompt's text stays in later requests. "The last
# user message holds BGSHELL20" therefore cannot tell a new prompt from the follow-up to its tool
# call, and answering every request that holds the token would call the tool for ever. Each token
# is answered once; give a second task a different number.
answered, answered_lock = set(), threading.Lock()

def first_time(token):
    with answered_lock:
        if token in answered:
            return False
        answered.add(token)
        return True

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

    def _stream_then_stall(self, body, seconds):
        """An answer that has started (a line of text is on screen) and then stops arriving."""
        model = body.get("model", "stub")

        def chunk(events):
            data = "".join(f"event: {name}\ndata: {json.dumps(payload)}\n\n" for name, payload in events).encode()
            return f"{len(data):x}\r\n".encode() + data + b"\r\n"
        first = chunk([
            ("message_start", {"type": "message_start", "message": {"id": "msg_stall", "type": "message", "role": "assistant",
                               "model": model, "content": [], "stop_reason": None, "stop_sequence": None,
                               "usage": {"input_tokens": 10, "output_tokens": 1}}}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                     "delta": {"type": "text_delta", "text": "The beginning of a long answer."}}),
        ])
        rest = chunk([
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 3}}),
            ("message_stop", {"type": "message_stop"}),
        ])
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()
        try:
            self.wfile.write(first); self.wfile.flush()
            time.sleep(seconds)
            self.wfile.write(rest + b"0\r\n\r\n"); self.wfile.flush()
        except Exception:
            pass   # the client gave up (an Esc or Ctrl+C): that is the point

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
             "user_len": len(text), "probes": re.findall(r"[A-Z][A-Z0-9_]{5,}", text[-600:]),
             "shape": [(m.get("role"), [p.get("type") for p in m["content"] if isinstance(p, dict)] if isinstance(m.get("content"), list) else "str")
                       for m in body.get("messages", [])[-4:]]})
        reply = "STUB-REPLY"
        usage = {"input_tokens": 10, "output_tokens": 3}
        scripted = None
        if "haiku" not in (body.get("model") or "") and body.get("stream"):
            work, shell, agent, slow, stall, perm, askslow, mcp = (
                re.search(token + r"(\d+)", text)
                for token in ("SUBWORK", "BGSHELL", "BGAGENT", "SLOW", "STREAM", "ASKPERM", "PERMWAIT", "MCPCALL"))
            work, shell, agent, slow, stall, perm, askslow, mcp = (
                m if m and first_time(m.group(0)) else None for m in (work, shell, agent, slow, stall, perm, askslow, mcp))
            if slow:
                time.sleep(int(slow.group(1)))
                reply = "SLOW-DONE"
            elif stall:
                self._stream_then_stall(body, int(stall.group(1)))
                return
            elif perm:
                scripted = ("Bash", {"command": "touch permtest.txt", "description": "make a file"})
            elif askslow:
                scripted = ("Bash", {"command": f"touch permtest.txt; sleep {askslow.group(1)}",
                                     "description": f"make a file, then wait {askslow.group(1)} seconds"})
            elif mcp:
                scripted = ("mcp__probe__slow", {"seconds": int(mcp.group(1))})
            elif work:
                time.sleep(int(work.group(1)))
                reply = "SUBAGENT-DONE"
            elif shell:
                scripted = ("Bash", {"command": f"sleep {shell.group(1)}", "description": f"stub shell {shell.group(1)}s",
                                     "run_in_background": True})
            elif agent:
                scripted = ("Agent", {"description": f"stub agent {agent.group(1)}s", "subagent_type": "general-purpose",
                                      "prompt": f"SUBWORK{agent.group(1)} do the stub work", "run_in_background": True})
        if not body.get("stream"):
            self._send_json(200, {"id": "msg_stub", "type": "message", "role": "assistant", "model": body.get("model", "stub"),
                                  "content": [{"type": "text", "text": reply}], "stop_reason": "end_turn",
                                  "stop_sequence": None, "usage": usage})
            return
        if scripted:
            name, tool_input = scripted
            block = {"type": "tool_use", "id": f"toolu_stub{int(time.time() * 1000)}", "name": name, "input": {}}
            delta = {"type": "input_json_delta", "partial_json": json.dumps(tool_input)}
            stop = "tool_use"
        else:
            block = {"type": "text", "text": ""}
            delta = {"type": "text_delta", "text": reply}
            stop = "end_turn"
        events = [
            ("message_start", {"type": "message_start", "message": {"id": "msg_stub", "type": "message", "role": "assistant",
                               "model": body.get("model", "stub"), "content": [], "stop_reason": None, "stop_sequence": None,
                               "usage": {"input_tokens": 10, "output_tokens": 1}}}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": block}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": delta}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 3}}),
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
