#!/usr/bin/env python3
"""Loopback SP-API fixture with deterministic throttling and report states."""

import argparse
import gzip
import json
import re
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


REPORTS = "/reports/2021-06-30"
REPORT_ID = "mock-report"
DOCUMENT_ID = "mock-document"
ACCESS = "mock-token"
SIGNATURE = re.compile(
    r"AWS4-HMAC-SHA256 Credential=mock-id/(\d{8})/"
    r"(?:us-east-1|eu-west-1|us-west-2)/execute-api/aws4_request, "
    r"SignedHeaders=host;x-amz-access-token;x-amz-date, Signature=[0-9a-f]{64}"
)
COUNTERS = (
    "lwa_requests", "signed_requests", "auth_rejections", "report_create_attempts",
    "throttled", "report_polls", "in_progress", "downloads",
)


class MockServer(HTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.base_url = f"http://127.0.0.1:{self.server_port}"
        self.stats = dict.fromkeys(COUNTERS, 0)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # The fixture only exposes aggregate counts.
        pass

    def send_body(self, status, body, content_type, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, status, value, headers=None):
        self.send_body(status, json.dumps(value).encode(), "application/json", headers)

    def authorized(self):
        stamp = self.headers.get("x-amz-date", "")
        signature = SIGNATURE.fullmatch(self.headers.get("Authorization", ""))
        if (
            self.headers.get("x-amz-access-token") == ACCESS
            and re.fullmatch(r"\d{8}T\d{6}Z", stamp)
            and signature
            and signature.group(1) == stamp[:8]
        ):
            self.server.stats["signed_requests"] += 1
            return True
        self.server.stats["auth_rejections"] += 1
        self.send_json(403, {"errors": [{"code": "Unauthorized"}]})
        return False

    def do_POST(self):
        if self.path not in ("/auth/o2/token", REPORTS + "/reports"):
            self.send_json(404, {"error": "Unknown route"})
            return
        if self.path != "/auth/o2/token" and not self.authorized():
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                raise ValueError
            body = self.rfile.read(length)
            if self.path == "/auth/o2/token":
                form = parse_qs(body.decode("utf-8"), strict_parsing=True)
                if (
                    self.headers.get_content_type() != "application/x-www-form-urlencoded"
                    or form.get("grant_type") != ["refresh_token"]
                    or not all(len(form.get(key, [])) == 1
                               for key in ("client_id", "client_secret", "refresh_token"))
                ):
                    raise ValueError
            else:
                report = json.loads(body)
                start = datetime.fromisoformat(report["dataStartTime"])
                end = datetime.fromisoformat(report["dataEndTime"])
                markets = report["marketplaceIds"]
                if (
                    self.headers.get_content_type() != "application/json"
                    or not report["reportType"]
                    or not isinstance(markets, list)
                    or len(markets) != 1
                    or not markets[0]
                    or start.utcoffset() is None
                    or end.utcoffset() is None
                    or start >= end
                ):
                    raise ValueError
        except (ValueError, TypeError, KeyError):
            self.send_json(400, {"error": "Invalid request body"})
            return

        if self.path == "/auth/o2/token":
            self.server.stats["lwa_requests"] += 1
            self.send_json(200, {"access_token": ACCESS, "expires_in": 3600})
            return
        self.server.stats["report_create_attempts"] += 1
        if self.server.stats["report_create_attempts"] == 1:
            self.server.stats["throttled"] += 1
            self.send_json(429, {"errors": [{"code": "QuotaExceeded"}]}, {"Retry-After": "0"})
            return
        self.send_json(200, {"reportId": REPORT_ID})

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/stats":
            self.send_json(200, self.server.stats)
            return
        if url.path == f"/docs/{DOCUMENT_ID}":
            if "Authorization" in self.headers or "x-amz-access-token" in self.headers:
                self.send_json(400, {"error": "Download must be unsigned"})
                return
            report = {
                "salesAndTrafficByDate": [{"date": "2026-01-01", "salesByDate": {"unitsOrdered": 2}}],
                "salesAndTrafficByAsin": [{"parentAsin": "B0MOCK0001"}],
            }
            self.server.stats["downloads"] += 1
            self.send_body(200, gzip.compress(json.dumps(report).encode()), "application/octet-stream")
            return
        if not self.authorized():
            return

        item = re.fullmatch(r"/catalog/2022-04-01/items/([A-Z0-9]{10})", url.path)
        if item:
            query = parse_qs(url.query)
            market = query.get("marketplaceIds", [])
            if len(market) != 1 or query.get("includedData") != ["summaries,attributes"]:
                self.send_json(400, {"error": "Invalid catalog query"})
                return
            self.send_json(200, {"asin": item.group(1), "attributes": {},
                                 "summaries": [{"marketplaceId": market[0], "itemName": "Fixture item"}]})
        elif url.path == f"{REPORTS}/reports/{REPORT_ID}":
            self.server.stats["report_polls"] += 1
            report = {"reportId": REPORT_ID, "processingStatus": "IN_PROGRESS"}
            if self.server.stats["report_polls"] <= 2:
                self.server.stats["in_progress"] += 1
            else:
                report.update(processingStatus="DONE", reportDocumentId=DOCUMENT_ID)
            self.send_json(200, report)
        elif url.path == f"{REPORTS}/documents/{DOCUMENT_ID}":
            self.send_json(200, {"reportDocumentId": DOCUMENT_ID, "compressionAlgorithm": "GZIP",
                                 "url": f"{self.server.base_url}/docs/{DOCUMENT_ID}"})
        else:
            self.send_json(404, {"error": "Unknown route"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-file", required=True, type=Path, help="Write the bound port to this file")
    args = parser.parse_args()
    with MockServer() as server:
        print(f"SP-API mock listening on {server.base_url}", flush=True)
        args.port_file.write_text(str(server.server_port) + "\n", encoding="ascii")
        server.serve_forever()


if __name__ == "__main__":
    main()
