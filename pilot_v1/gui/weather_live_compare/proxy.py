#!/usr/bin/env python3
"""
Local proxy server for weather GUI.
Forwards /api/weather/* requests to Worker 1 to bypass CORS.
Run: python proxy.py [worker_base_url]
Default worker URL: https://jawed-lapel-dispersed.ngrok-free.dev
GUI is served at http://127.0.0.1:8080
"""
import sys
import os
import json
import urllib.request
import urllib.error
from http.server import HTTPServer, SimpleHTTPRequestHandler

WORKER_BASE = sys.argv[1].rstrip('/') if len(sys.argv) > 1 else "https://jawed-lapel-dispersed.ngrok-free.dev"
GUI_DIR = os.path.dirname(os.path.abspath(__file__))

class ProxyHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=GUI_DIR, **kwargs)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/api/weather"):
            self._proxy("GET", self.path, None)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/weather"):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else None
            self._proxy("POST", self.path, body)
        else:
            self.send_response(404)
            self.end_headers()

    def _proxy(self, method, path, body):
        target = WORKER_BASE + path
        try:
            req = urllib.request.Request(target, data=body, method=method)
            req.add_header("Content-Type", "application/json")
            req.add_header("ngrok-skip-browser-warning", "1")
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
                self.send_response(resp.status)
                self._cors()
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self._cors()
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_response(502)
            self._cors()
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": str(e)}).encode())

    def log_message(self, fmt, *args):
        print(f"[proxy] {self.address_string()} - {fmt % args}")

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8080), ProxyHandler)
    print(f"Proxy + GUI server running at http://127.0.0.1:8080")
    print(f"Forwarding /api/weather/* → {WORKER_BASE}")
    print("Press Ctrl+C to stop.")
    server.serve_forever()
