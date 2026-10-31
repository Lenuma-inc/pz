"""Loopback Streamable HTTP MCP peer; checks session, protocol and custom headers."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

mode = sys.argv[1]

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(raw)
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/do-not-follow")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if mode == "unauthorized":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        assert self.headers["Authorization"] == "Bearer fixture-secret"
        assert self.headers["MCP-Protocol-Version"] == "2024-11-05"
        method = request["method"]
        if method != "initialize":
            assert self.headers["Mcp-Session-Id"] == "fixture-session"
        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if method == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "http-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "http_echo", "description": "HTTP echo", "inputSchema": {"type": "object"}}]}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": request["params"]["arguments"]["text"]}]}
        else:
            raise AssertionError(method)
        response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        self.send_response(200)
        if method == "initialize":
            self.send_header("Mcp-Session-Id", "fixture-session")
        if mode == "sse":
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            notice = json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"data": "progress"}})
            self.wfile.write((": keepalive\r\n\r\ndata: " + notice + "\r\n\r\nevent: message\r\ndata: " + json.dumps(response) + "\r\n\r\n").encode())
            self.wfile.flush()
            # Deliberately keep the stream open: client must stop at the JSON-RPC reply.
        else:
            body = json.dumps(response).encode()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

server = HTTPServer(("127.0.0.1", 0), Handler)
print("http://127.0.0.1:%d/mcp" % server.server_port, flush=True)
server.serve_forever()
