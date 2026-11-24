#!/usr/bin/env python3
"""Search eBay listings or check application credential expiry."""

import argparse
import base64
import http.client
import json
import math
import os
import re
import sys
import tempfile
import time
from contextlib import suppress
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


ORIGINS = {
    "sandbox": "https://api.sandbox.ebay.com",
    "production": "https://api.ebay.com",
}
LOOPBACK = {"127.0.0.1", "::1", "localhost"}
MARKETPLACES = ("EBAY_US", "EBAY_GB", "EBAY_DE", "EBAY_AU")
CREDENTIALS = ("EBAY_CLIENT_ID", "EBAY_CLIENT_SECRET")
SCOPE = "https://api.ebay.com/oauth/api_scope"

EXIT_CODES = {
    "E_EBAY_CONFIG": 2,
    "E_EBAY_AUTH": 3,
    "E_EBAY_THROTTLED": 4,
    "E_EBAY_HTTP": 5,
    "E_EBAY_NET": 6,
}
HTTP_CODES = {401: "E_EBAY_AUTH", 403: "E_EBAY_AUTH", 429: "E_EBAY_THROTTLED"}


class EbayError(Exception):
    def __init__(self, code, **details):
        super().__init__(code)
        self.code = code
        self.details = details


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Keep Authorization scoped to the configured origin.
        return None


def retry_delay(header, fallback):
    if not header:
        return fallback
    value = header.strip()
    if value.isascii() and value.isdigit():
        seconds = float(value)
        return seconds if math.isfinite(seconds) else fallback
    try:
        when = parsedate_to_datetime(value)
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        return max(0, (when - datetime.now(timezone.utc)).total_seconds())
    except (ValueError, TypeError, OverflowError):
        return fallback


class EbayClient:
    def __init__(self, environment, base_url):
        credentials = {name: os.environ.get(name) for name in CREDENTIALS}
        missing = [name for name, value in credentials.items() if not value]
        if missing:
            raise EbayError("E_EBAY_CONFIG", missing=missing)
        client_id, client_secret = (credentials[name] for name in CREDENTIALS)
        basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode("ascii")
        self.basic = basic
        self.sensitive_values = {client_id, client_secret, basic}

        self.origin = ORIGINS[environment] if base_url is None else base_url.rstrip("/")
        try:
            origin = urlsplit(self.origin)
            local = origin.hostname in LOOPBACK
            if (
                not origin.hostname or origin.username is not None or origin.port == 0
                or origin.path or origin.query or origin.fragment
                or (origin.scheme != "https" and not (origin.scheme == "http" and local))
            ):
                raise ValueError
        except ValueError:
            raise EbayError("E_EBAY_CONFIG", message="Invalid base URL") from None
        self.opener = (build_opener(ProxyHandler({}), NoRedirect()) if local
                       else build_opener(NoRedirect()))
        self.access = None
        self.expires_at = 0

    def request_json(self, make_request):
        for fallback in (2, 4, 8, None):
            request = make_request()
            try:
                with self.opener.open(request, timeout=30) as response:
                    body = response.read()
            except HTTPError as error:
                with error:
                    status = error.code
                    retry_after = error.headers.get("Retry-After")
                if status == 429 and fallback is not None:
                    try:
                        time.sleep(retry_delay(retry_after, fallback))
                    except OverflowError:
                        raise EbayError("E_EBAY_NET", message="Retry delay exceeds system limit") from None
                    continue
                raise EbayError(HTTP_CODES.get(status, "E_EBAY_HTTP"), status=status) from None
            except (OSError, http.client.HTTPException, ValueError):
                raise EbayError("E_EBAY_NET", message="Request failed or timed out") from None
            try:
                data = json.loads(body)
            except (ValueError, RecursionError):
                raise EbayError("E_EBAY_HTTP", message="Invalid JSON response") from None
            if not isinstance(data, dict):
                raise EbayError("E_EBAY_HTTP", message="Expected a JSON object")
            return data

    def application_token(self):
        now = time.monotonic()
        if now < self.expires_at - 60:
            return self.access, math.ceil(self.expires_at - now)

        request = Request(
            self.origin + "/identity/v1/oauth2/token",
            data=urlencode({"grant_type": "client_credentials", "scope": SCOPE}).encode("ascii"),
            headers={
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": f"Basic {self.basic}",
            },
        )
        data = self.request_json(lambda: request)
        access, lifetime = data.get("access_token"), data.get("expires_in")
        if (not isinstance(access, str) or not re.fullmatch(r"[!-~]+", access)
                or type(lifetime) is not int or lifetime <= 0):
            raise EbayError("E_EBAY_HTTP", message="Invalid OAuth response")
        try:
            self.expires_at = time.monotonic() + lifetime
        except OverflowError:
            raise EbayError("E_EBAY_HTTP", message="Invalid OAuth expiry") from None
        self.access = access
        self.sensitive_values.add(access)
        return access, lifetime

    def search(self, query, site, limit):
        url = self.origin + "/buy/browse/v1/item_summary/search?" + urlencode({"q": query, "limit": limit})

        def request():
            access, _ = self.application_token()
            return Request(url, headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {access}",
                "X-EBAY-C-MARKETPLACE-ID": site,
            })

        data = self.request_json(request)
        items = data.get("itemSummaries", [])
        if not isinstance(items, list):
            raise EbayError("E_EBAY_HTTP", message="Invalid itemSummaries")
        return [item_summary(item) for item in items]

    def check_output(self, serialized):
        # Keep credential values out of results even if a response echoes one.
        if any(json.dumps(value, ensure_ascii=False)[1:-1] in serialized
               for value in self.sensitive_values):
            raise EbayError("E_EBAY_HTTP", message="Credential material in output")


def item_summary(item):
    if (not isinstance(item, dict) or not isinstance(item.get("itemId"), str)
            or not item["itemId"] or not isinstance(item.get("title"), str)):
        raise EbayError("E_EBAY_HTTP", message="Invalid item summary")
    price = item.get("price")
    if price is not None:
        if (not isinstance(price, dict) or not isinstance(price.get("value"), str)
                or not isinstance(price.get("currency"), str)):
            raise EbayError("E_EBAY_HTTP", message="Invalid item price")
        price = {"value": price["value"], "currency": price["currency"]}
    return {"itemId": item["itemId"], "title": item["title"], "price": price}


def write_result(path, content):
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".ebay-search-", delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
        temporary.replace(path)
        temporary = None
    except (OSError, ValueError):
        raise EbayError("E_EBAY_HTTP", message="Unable to write output") from None
    finally:
        if temporary is not None:
            with suppress(OSError):
                temporary.unlink(missing_ok=True)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    connection = argparse.ArgumentParser(add_help=False)
    connection.add_argument("--env", choices=ORIGINS, default="sandbox",
                            help="eBay environment (default: sandbox)")
    connection.add_argument("--base-url", help="Override the API origin for local testing")
    commands = parser.add_subparsers(dest="command", required=True)
    search = commands.add_parser("search", parents=[connection], help="Search item summaries")
    search.add_argument("--q", required=True, help="Search keywords")
    search.add_argument("--site", choices=MARKETPLACES, default="EBAY_US",
                        help="Marketplace ID (default: EBAY_US)")
    search.add_argument("--limit", type=int, default=20, help="Result limit, 1 to 200 (default: 20)")
    search.add_argument("--out", type=Path, default=Path("out"), help="Output directory (default: out)")
    commands.add_parser("token", parents=[connection], help="Print only the application credential lifetime")
    return parser.parse_args()


def main():
    args = parse_args()
    try:
        client = EbayClient(args.env, args.base_url)
        if args.command == "token":
            _, lifetime = client.application_token()
            print(json.dumps({"expires_in": lifetime}))
            return 0

        if not args.q.strip() or not 1 <= args.limit <= 200:
            raise EbayError("E_EBAY_CONFIG", message="Search requires keywords and a limit from 1 to 200")
        items = client.search(args.q, args.site, args.limit)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = args.out / f"ebay_search_{stamp}.json"
        content = json.dumps({"itemSummaries": items}, ensure_ascii=False, indent=2) + "\n"
        summary = json.dumps({"items": len(items), "out": str(path)}, ensure_ascii=False)
        client.check_output(content)
        client.check_output(summary)
        write_result(path, content)
        print(summary)
        return 0
    except EbayError as error:
        print(json.dumps({"code": error.code, **error.details}), file=sys.stderr)
        return EXIT_CODES[error.code]


if __name__ == "__main__":
    sys.exit(main())
