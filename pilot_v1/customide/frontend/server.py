from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


ROOT_DIR = Path(__file__).resolve().parent
CUSTOMIDE_ROOT = ROOT_DIR.parent


class NoCacheHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        request_path = path.split("?", 1)[0].split("#", 1)[0]

        if request_path == "/TOKEN_COUNTER_TASKS.txt":
            return str(CUSTOMIDE_ROOT / "TOKEN_COUNTER_TASKS.txt")

        if request_path == "/state" or request_path.startswith("/state/"):
            return str(CUSTOMIDE_ROOT / request_path.lstrip("/"))

        if request_path == "/config" or request_path.startswith("/config/"):
            return str(CUSTOMIDE_ROOT / request_path.lstrip("/"))

        return super().translate_path(path)

    def end_headers(self):
        # Prevent stale cockpit shell (index.html/css/js) from being reused.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 5570), NoCacheHandler)
    server.serve_forever()
