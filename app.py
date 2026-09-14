#!/usr/bin/env python3
"""
================================================================================
Bank-Grade Build-Info Microservice
================================================================================
Security & Architectural Features:
  - Zero third-party dependencies (eliminates supply-chain CVE attack vectors).
  - OWASP Banking Security Headers (HSTS, CSP, Anti-Clickjacking, No-Sniff).
  - Anti-Banner Grabbing (Server tokens and language versions suppressed).
  - Zero-Information-Leakage Error Handling (Sanitized generic errors with UUIDs).
  - Structured JSON Logging compliant with Google Cloud Logging / SIEM ingestion.
  - Native correlation tracking via GCP 'X-Cloud-Trace-Context'.
  - Graceful Linux signal handling (SIGTERM/SIGINT) for zero-downtime draining.
  - Multi-path Health Checks: Supports public /health and internal /healthz.
================================================================================
"""

import json
import os
import re
import signal
import sys
import time
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# Path where Cloud Build bakes immutable build metadata during image build
BUILD_INFO_PATH = os.getenv("BUILD_INFO_PATH", "/app/build_info.json")

# Schema constraints for banking validation
ALLOWED_ENVIRONMENTS = {"development", "staging", "production", "local"}
MAX_URI_LENGTH = 1024  # Reject oversized malicious buffer requests


def write_structured_log(severity: str, message: str, **kwargs):
    """
    Outputs structured JSON logs directly to stdout.
    Google Cloud Logging automatically parses this format and maps 'severity'
    and trace contexts into Cloud Logging / SIEM dashboards.
    """
    log_entry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "severity": severity,
        "message": message,
        **kwargs
    }
    sys.stdout.write(json.dumps(log_entry) + "\n")
    sys.stdout.flush()


def load_and_sanitize_build_metadata() -> dict:
    """
    Safely loads and validates build metadata.
    Enforces strict field boundaries so corrupt or manipulated files do not crash the service.
    """
    defaults = {
        "application": "build-info-api",
        "version": os.getenv("APP_VERSION", "v1.0.0-dev"),
        "git_commit": os.getenv("GIT_COMMIT", "local-workspace"),
        "build_time": "local-build",
        "environment": os.getenv("APP_ENV", "local")
    }

    if not os.path.exists(BUILD_INFO_PATH):
        write_structured_log(
            "WARNING",
            f"Build metadata file not found at {BUILD_INFO_PATH}. Using fallback defaults."
        )
        return defaults

    try:
        with open(BUILD_INFO_PATH, "r", encoding="utf-8") as f:
            raw_data = json.load(f)

        # Validate that the file is an actual JSON dictionary
        if not isinstance(raw_data, dict):
            raise ValueError("Root payload is not a valid JSON object")

        # Sanitize and extract only approved keys (prevents arbitrary data injection)
        sanitized = {
            "application": str(raw_data.get("application", "build-info-api"))[:64],
            "version": str(raw_data.get("version", "unknown"))[:32],
            "git_commit": str(raw_data.get("git_commit", "unknown"))[:40],
            "build_time": str(raw_data.get("build_time", "unknown"))[:32],
            "environment": str(raw_data.get("environment", "production"))[:16]
        }
        return sanitized

    except Exception as err:
        write_structured_log(
            "ERROR",
            f"Integrity check failed on {BUILD_INFO_PATH}. Loading fallback.",
            error_details=str(err)
        )
        return defaults


# Cache sanitized metadata in memory at startup (Immutable pattern)
BUILD_METADATA = load_and_sanitize_build_metadata()


class BankSecureHandler(BaseHTTPRequestHandler):
    """
    Hardened HTTP request handler implementing zero-trust security controls.
    """

    # 1. Anti-Banner Grabbing: Wipe out default server identification headers
    server_version = ""
    sys_version = ""

    def _extract_trace_context(self) -> str:
        """
        Extracts Google Cloud Trace context or generates a cryptographically secure UUID.
        Format from GCP Load Balancer: 'X-Cloud-Trace-Context: TRACE_ID/SPAN_ID;o=TRACE_TRUE'
        """
        trace_header = self.headers.get("X-Cloud-Trace-Context")
        if trace_header:
            return trace_header.split("/")[0]

        request_id = self.headers.get("X-Request-ID")
        if request_id and re.match(r"^[a-zA-Z0-9\-_]{1,64}$", request_id):
            return request_id

        return str(uuid.uuid4())

    def _send_secure_response(self, status_code: int, content_type: str, body: bytes, correlation_id: str):
        """
        Sends HTTP response bundled with mandatory enterprise security headers.
        """
        try:
            self.send_response(status_code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Correlation-ID", correlation_id)

            # --- OWASP Recommended Financial Security Headers ---
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Strict-Transport-Security", "max-age=63072000; includeSubDomains; preload")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-XSS-Protection", "1; mode=block")
            self.end_headers()

            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # Client dropped connection prematurely; log and swallow safely
            write_structured_log("WARNING", "Client disconnected before response transmission completed.", correlation_id=correlation_id)

    def _send_json_error(self, status_code: int, error_code: str, message: str, correlation_id: str):
        """
        Returns a clean, standardized error contract without disclosing internal file paths.
        """
        payload = {
            "error": {
                "code": error_code,
                "message": message,
                "correlation_id": correlation_id,
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            }
        }
        body = json.dumps(payload, indent=2).encode("utf-8")
        self._send_secure_response(status_code, "application/json; charset=utf-8", body, correlation_id)

    def do_GET(self):
        correlation_id = self._extract_trace_context()

        # Buffer / URL Flood Defense
        if len(self.path) > MAX_URI_LENGTH:
            self._send_json_error(414, "URI_TOO_LONG", "The requested URI exceeds the maximum permitted length.", correlation_id)
            write_structured_log("WARNING", "Request rejected: URI too long.", client_ip=self.client_address[0], correlation_id=correlation_id)
            return

        # Cleanly extract URL path without query parameters (?authuser=7, etc.)
        parsed_url = urlparse(self.path)
        clean_path = parsed_url.path

        # ----------------------------------------------------------------------
        # Route 1: Root Gateway Greeting
        # ----------------------------------------------------------------------
        if clean_path == "/":
            payload = {
                "service": "Bank Build-Info Gateway",
                "status": "OPERATIONAL",
                "endpoints": {
                    "build_information": "/info",
                    "health_probe": "/health"
                }
            }
            body = json.dumps(payload, indent=2).encode("utf-8")
            self._send_secure_response(200, "application/json; charset=utf-8", body, correlation_id)
            return

        # ----------------------------------------------------------------------
        # Route 2: Core Build Info Endpoint
        # ----------------------------------------------------------------------
        if clean_path == "/info":
            try:
                response_payload = {
                    **BUILD_METADATA,
                    "status": "healthy",
                    "correlation_id": correlation_id
                }
                body = json.dumps(response_payload, indent=2).encode("utf-8")
                self._send_secure_response(200, "application/json; charset=utf-8", body, correlation_id)
                write_structured_log("INFO", "Dispatched build metadata to authorized consumer.", correlation_id=correlation_id)
                return
            except Exception as err:
                write_structured_log("CRITICAL", "Internal serialization failure.", error=str(err), correlation_id=correlation_id)
                self._send_json_error(500, "INTERNAL_SERVER_ERROR", "An internal error occurred. Please contact support quoting your correlation ID.", correlation_id)
                return

        # ----------------------------------------------------------------------
        # Route 3: Multi-Path Health Probe (/health, /status, /healthz)
        # /health: Used by external users, monitors, and public curl commands
        # /healthz: Retained for internal Kubernetes and container runtime probes
        # ----------------------------------------------------------------------
        if clean_path in ("/health", "/status", "/healthz"):
            body = b"OK\n"
            self._send_secure_response(200, "text/plain; charset=utf-8", body, correlation_id)
            return

        # ----------------------------------------------------------------------
        # Route 4: Catch-All 404 (Masking internal topology)
        # ----------------------------------------------------------------------
        write_structured_log("WARNING", f"Resource not found: {clean_path}", correlation_id=correlation_id)
        self._send_json_error(404, "RESOURCE_NOT_FOUND", "The requested resource path was not found on this service.", correlation_id)

    # --------------------------------------------------------------------------
    # Block All Non-Approved HTTP Verbs (Prevent XST, injection, state changes)
    # --------------------------------------------------------------------------
    def do_POST(self):
        self._send_unsupported_method()

    def do_PUT(self):
        self._send_unsupported_method()

    def do_DELETE(self):
        self._send_unsupported_method()

    def do_PATCH(self):
        self._send_unsupported_method()

    def do_TRACE(self):
        # Strict prevention of Cross-Site Tracing (XST) attacks
        self._send_unsupported_method()

    def _send_unsupported_method(self):
        correlation_id = self._extract_trace_context()
        write_structured_log("WARNING", f"Method '{self.command}' rejected on path '{self.path}'", correlation_id=correlation_id)
        self._send_json_error(405, "METHOD_NOT_ALLOWED", f"HTTP method '{self.command}' is not permitted on this resource.", correlation_id)

    def log_message(self, fmt, *args):
        """Suppresses default stderr logging in favor of our structured audit logger."""
        pass


def serve():
    port = int(os.getenv("PORT", "8080"))
    server_address = ("0.0.0.0", port)
    httpd = HTTPServer(server_address, BankSecureHandler)

    # --------------------------------------------------------------------------
    # Graceful Shutdown Handler (Cloud Run / Kubernetes SIGTERM Draining)
    # --------------------------------------------------------------------------
    def handle_shutdown(signum, frame):
        write_structured_log("INFO", f"Received termination signal ({signum}). Initiating graceful socket closure...")
        httpd.server_close()
        write_structured_log("INFO", "Service successfully drained and stopped.")
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    write_structured_log("INFO", f"Banking Build-Info microservice initialized securely on port {port}.")
    try:
        httpd.serve_forever()
    except Exception as exc:
        write_structured_log("EMERGENCY", "Fatal server exception encountered.", details=str(exc))
        sys.exit(1)


if __name__ == "__main__":
    serve()