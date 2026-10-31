"""Deterministic stdio MCP peer used by pz integration tests (no SDK/network)."""
import json
import os
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
initialized = False

def send(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "notifications/initialized":
        initialized = True
        continue
    if method == "initialize":
        if mode == "verbose":
            sys.stderr.write("MCP-STDERR-MUST-NOT-REACH-TUI\n" * 10000)
            sys.stderr.flush()
        if mode == "hang":
            time.sleep(60)
        if mode == "malformed":
            print("not json", flush=True)
            continue
        if mode == "large":
            print("x" * (1024 * 1024 + 1), flush=True)
            continue
        result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "tools/list":
        assert initialized, "client skipped initialized notification"
        if mode == "cursor":
            result = {"tools": [], "nextCursor": "same"}
        else:
            page = request.get("params", {}).get("cursor")
            result = {"tools": [{"name": "second" if page else "echo.tool", "description": ("Large fixture description " * 300 + "MCP-LARGE-OUTPUT-END") if mode == "verbose" else "Fixture echo", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"], "additionalProperties": False}}]}
            if not page:
                result["nextCursor"] = "page2"
                send({"jsonrpc": "2.0", "method": "notifications/message", "params": {"data": "fixture notification"}})
                send({"jsonrpc": "2.0", "id": "ping1", "method": "ping"})
                response = json.loads(sys.stdin.readline())
                assert response == {"jsonrpc": "2.0", "id": "ping1", "result": {}}
    elif method == "tools/call":
        if mode == "callhang":
            time.sleep(60)
        if mode == "rpc":
            send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32602, "message": "fixture remote error"}})
            continue
        result = {"content": [{"type": "text", "text": request["params"]["arguments"]["text"]}], "structuredContent": {"remote": request["params"]["name"], "env": os.environ.get("PZ_MCP_FIXTURE")}, "isError": mode == "tool_error"}
    else:
        raise AssertionError(method)
    send({"jsonrpc": "2.0", "id": request["id"] + (1 if mode == "wrongid" else 0), "result": result})
