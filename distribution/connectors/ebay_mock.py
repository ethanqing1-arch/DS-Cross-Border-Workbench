#!/usr/bin/env python3
"""Serve the eBay OAuth and Browse fixtures on a random loopback port."""

import argparse
import base64
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


TOKEN_PATH = "/identity/v1/oauth2/token"
SEARCH_PATH = "/buy/browse/v1/item_summary/search"
SCOPE = "https://api.ebay.com/oauth/api_scope"
MARKETPLACES = {"EBAY_US", "EBAY_GB", "EBAY_DE", "EBAY_AU"}
ITEMS = [
    {"itemId": "v1|10001|0", "title": "Wireless Earbuds", "price": {"value": "29.99", "currency": "USD"}},
    {"itemId": "v1|10002|0", "title": "Wireless Earbuds with Case",
     "price": {"value": "39.50", "currency": "USD"}},
]


class MockServer(HTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), MockHandler)
        self.stats = {
            "token_requests": 0,
            "browse_requests": 0,
            "throttled_count": 0,
            "last_marketplace": None,
            "last_basic_ok": False,
        }


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_json(self, status, data, **headers):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def reject_auth(self):
        self.send_json(401, {"errors": [{
            "errorId": 1001,
            "domain": "OAuth",
            "category": "REQUEST",
            "message": "Invalid credentials or marketplace",
        }]})

    def valid_basic(self):
        scheme, _, encoded = self.headers.get("Authorization", "").partition(" ")
        if scheme.lower() != "basic":
            return False
        try:
            return base64.b64decode(encoded, validate=True) == b"mock-id:mock-secret"
        except ValueError:
            return False

    def do_POST(self):
        if self.path != TOKEN_PATH:
            self.send_json(404, {"error": "Unknown route"})
            return
        stats = self.server.stats
        stats["token_requests"] += 1
        stats["last_basic_ok"] = self.valid_basic()
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 1 <= size <= 4096:
                raise ValueError
            form = parse_qs(self.rfile.read(size).decode("ascii"))
        except ValueError:
            self.reject_auth()
            return
        if (not stats["last_basic_ok"]
                or self.headers.get_content_type() != "application/x-www-form-urlencoded"
                or form.get("grant_type") != ["client_credentials"] or form.get("scope") != [SCOPE]):
            self.reject_auth()
            return
        self.send_json(200, {"access_token": "mock-token", "expires_in": 3600})

    def do_GET(self):
        url = urlsplit(self.path)
        stats = self.server.stats
        if url.path == "/_stats":
            self.send_json(200, stats)
            return
        if url.path != SEARCH_PATH:
            self.send_json(404, {"error": "Unknown route"})
            return
        stats["browse_requests"] += 1
        marketplace = self.headers.get("X-EBAY-C-MARKETPLACE-ID")
        stats["last_marketplace"] = marketplace if marketplace in MARKETPLACES else None
        if self.headers.get("Authorization") != "Bearer mock-token" or marketplace not in MARKETPLACES:
            self.reject_auth()
            return
        params = parse_qs(url.query)
        try:
            query, = params["q"]
            limit, = params["limit"]
            limit = int(limit)
            if not query.strip() or not 1 <= limit <= 200:
                raise ValueError
        except (KeyError, ValueError):
            self.send_json(400, {"error": "A keyword and a limit from 1 to 200 are required"})
            return
        if stats["throttled_count"] == 0:
            stats["throttled_count"] += 1
            self.send_json(429, {"error": "Too many requests"}, **{"Retry-After": "0"})
            return
        self.send_json(200, {"itemSummaries": ITEMS[:limit]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-file", required=True, type=Path, help="Write the bound port to this file")
    args = parser.parse_args()
    with MockServer() as server:
        print(f"eBay mock listening on http://127.0.0.1:{server.server_port}", flush=True)
        args.port_file.write_text(f"{server.server_port}\n", encoding="ascii")
        server.serve_forever()


if __name__ == "__main__":
    main()
