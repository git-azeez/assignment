#!/usr/bin/env python3
"""
Production-grade, zero-dependency Build Info microservice.
Exposes:
  - GET /info    : Returns immutable metadata stamped at container build time
  - GET /healthz : Standard liveness probe for Cloud Run health checking
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

BUILD_INFO_PATH = os.getenv("BUILD_INFO_PATH", "/app/build_info.json")

def load_build_metadata():
    """Reads build metadata baked into the container during Cloud Build."""
    if os.path.exists(BUILD_INFO_PATH):
        try:
            with open(BUILD_INFO_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as err:
            print(f"Warning: Could not parse {BUILD_INFO_PATH}: {err}", file=sys.stderr)

    # Local fallback for workstation development
    return {
        "application": "build-info-api",
        "version": os.getenv("APP_VERSION", "v1.0.0-dev"),
        "git_commit": os.getenv("GIT_COMMIT", "local-workspace"),
        "build_time": "local-run",
        "environment": os.getenv("APP_ENV", "local")
    }

BUILD_METADATA = load_build_metadata()

class BuildInfoHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/info":
            payload = {
                **BUILD_METADATA,
                "status": "healthy"
            }
            body = json.dumps(payload, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/healthz":
            body = b"OK\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        body = json.dumps({"error": "Not Found"}).encode("utf-8")
        self.send_response(404)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        """Format standard output logs for ingestion into Google Cloud Logging."""
        sys.stdout.write(f"[{self.log_date_time_string()}] {self.address_string()} - {fmt % args}\n")
        sys.stdout.flush()

def run():
    port = int(os.getenv("PORT", "8080"))
    server_address = ("0.0.0.0", port)
    httpd = HTTPServer(server_address, BuildInfoHandler)
    print(f"Service listening on port {port}...")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

if __name__ == "__main__":
    run()
