"""A minimal MCP server (stdio) with one tool that takes its time: `slow` {seconds}.

usage: mcp_probe.py            (Claude Code starts it from its MCP configuration)
Newline-delimited JSON-RPC 2.0, the stdio transport of the Model Context Protocol. It exists so that
state_sync.py can watch what the state icon does while Claude Code waits for an MCP server. No
dependency: standard library only.
"""
import json, sys, time


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except ValueError:
        continue
    method, ident = request.get("method"), request.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": ident, "result": {
            "protocolVersion": request.get("params", {}).get("protocolVersion", "2025-03-26"),
            "capabilities": {"tools": {}}, "serverInfo": {"name": "probe", "version": "1.0"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": ident, "result": {"tools": [{
            "name": "slow", "description": "Waits for the given number of seconds, then answers.",
            "inputSchema": {"type": "object", "properties": {"seconds": {"type": "integer"}}, "required": ["seconds"]}}]}})
    elif method == "tools/call":
        seconds = int((request.get("params", {}).get("arguments") or {}).get("seconds") or 1)
        time.sleep(seconds)
        send({"jsonrpc": "2.0", "id": ident, "result": {"content": [{"type": "text", "text": f"waited {seconds} s"}]}})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": ident, "result": {}})
    elif ident is not None:   # an unknown request still gets an answer
        send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "unknown method"}})
