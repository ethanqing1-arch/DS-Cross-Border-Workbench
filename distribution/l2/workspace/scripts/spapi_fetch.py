#!/usr/bin/env python3
"""Fetch Amazon SP-API catalog items and JSON reports."""

import argparse
import gzip
import hashlib
import hmac
import http.client
import json
import math
import re
import sys
import tempfile
import time
import zlib
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

import credentials


LWA_URL = "https://api.amazon.com/auth/o2/token"
REPORTS = "/reports/2021-06-30"
CREDENTIALS = credentials.SPAPI_CREDENTIALS
ENDPOINTS = {
    "NA": ("us-east-1", "https://sellingpartnerapi-na.amazon.com"),
    "EU": ("eu-west-1", "https://sellingpartnerapi-eu.amazon.com"),
    "FE": ("us-west-2", "https://sellingpartnerapi-fe.amazon.com"),
}
MARKETPLACES = {
    "BR": ("NA", "A2Q3Y263D00KWC"),
    "CA": ("NA", "A2EUQ1WTGCTBG2"),
    "MX": ("NA", "A1AM78C64UM0Y8"),
    "US": ("NA", "ATVPDKIKX0DER"),
    "AE": ("EU", "A2VIGQ35RCS4UG"),
    "BE": ("EU", "AMEN7PMS3EDWL"),
    "DE": ("EU", "A1PA6795UKMFR9"),
    "EG": ("EU", "ARBP9OOSHTCHU"),
    "ES": ("EU", "A1RKKUPIHCS9HS"),
    "FR": ("EU", "A13V1IB3VIYZZH"),
    "IE": ("EU", "A28R8C7NBKEWEA"),
    "IN": ("EU", "A21TJRUUN4KGV"),
    "IT": ("EU", "APJ6JRA9NG5V4"),
    "NL": ("EU", "A1805IZSGTT6HS"),
    "PL": ("EU", "A1C3SOZRARQ6R3"),
    "SA": ("EU", "A17E79C6D8DWNP"),
    "SE": ("EU", "A2NODRKZP88ZB9"),
    "TR": ("EU", "A33AVAJ2PDY3EV"),
    "UK": ("EU", "A1F83G8C2ARO7P"),
    "ZA": ("EU", "AE08WJ6YKNBMC"),
    "AU": ("FE", "A39IBJ37TRP1C6"),
    "JP": ("FE", "A1VC38T7YXB528"),
    "SG": ("FE", "A19VAU5U5O7RUS"),
}
LOOPBACK = {"127.0.0.1", "::1", "localhost"}
EXIT_CODES = {
    "E_SPAPI_CONFIG": 2,
    "E_SPAPI_AUTH": 3,
    "E_SPAPI_THROTTLED": 4,
    "E_SPAPI_HTTP": 5,
    "E_SPAPI_IO": 5,
    "E_SPAPI_NET": 6,
}


class SPAPIError(Exception):
    def __init__(self, code, **details):
        super().__init__(code)
        self.code = code
        self.details = details


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # urllib would normally forward request headers to the new origin.
        return None


def validated_url(url, code, local_http=False):
    try:
        parts = urlsplit(url)
        port = parts.port
        if (
            parts.hostname
            and parts.username is None
            and not parts.fragment
            and port != 0
            and (parts.scheme == "https" or (
                local_http and parts.scheme == "http" and parts.hostname in LOOPBACK
            ))
        ):
            return parts
    except ValueError:
        pass
    raise SPAPIError(code, message="Invalid endpoint URL")


def json_data(body, source):
    try:
        return json.loads(body)
    except (ValueError, RecursionError):
        raise SPAPIError("E_SPAPI_HTTP", message="Invalid JSON", source=source) from None


def object_data(body, source):
    value = json_data(body, source)
    if not isinstance(value, dict):
        raise SPAPIError("E_SPAPI_HTTP", message="Expected JSON object", source=source)
    return value


def response_string(value, field):
    result = value.get(field)
    if not isinstance(result, str) or not result:
        raise SPAPIError("E_SPAPI_HTTP", message="Missing response field", field=field)
    return result


def pause(seconds, deadline):
    if deadline is not None and seconds >= deadline - time.monotonic():
        raise SPAPIError("E_SPAPI_NET", message="Report polling deadline exceeded")
    try:
        time.sleep(seconds)
    except OverflowError:
        raise SPAPIError("E_SPAPI_NET", message="Retry delay exceeds system limit") from None


def retry_delay(header, fallback):
    if header:
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
            pass
    return fallback


def aws_encode(value):
    return quote(value, safe="-_.~")


def sign_request(method, path, query, body, host, region, client_id, access):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date = stamp[:8]
    scope = f"{date}/{region}/execute-api/aws4_request"
    headers = {"host": host, "x-amz-access-token": access, "x-amz-date": stamp}
    signed_headers = ";".join(sorted(headers))
    canonical_headers = "".join(f"{key}:{headers[key]}\n" for key in sorted(headers))
    canonical_path = quote(path, safe="/-_.~")
    canonical_request = "\n".join((
        method, canonical_path, query, canonical_headers, signed_headers, hashlib.sha256(body).hexdigest()
    ))
    algorithm = "AWS4-HMAC-SHA256"
    to_sign = "\n".join((
        algorithm, stamp, scope, hashlib.sha256(canonical_request.encode()).hexdigest()
    ))
    key = ("AWS4" + access).encode()
    for part in scope.split("/"):
        key = hmac.digest(key, part.encode(), "sha256")
    signature = hmac.new(key, to_sign.encode(), "sha256").hexdigest()
    headers["Authorization"] = (
        f"{algorithm} Credential={client_id}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    headers["User-Agent"] = "DS-Cross-Border-Workbench/0.1 (Language=Python)"
    return headers


class SPAPI:
    def __init__(self, marketplace, base_url):
        resolved = {name: credentials.resolve(name) for name in CREDENTIALS.values()}
        missing = credentials.missing(resolved)
        if missing:
            raise SPAPIError("E_SPAPI_CONFIG", missing=missing)
        self.credentials = {field: resolved[name] for field, name in CREDENTIALS.items()}
        self.sensitive_values = credentials.sensitive_values(CREDENTIALS.values())
        market_region, self.market_id = MARKETPLACES[marketplace]
        self.region, default_origin = ENDPOINTS[market_region]
        self.origin = base_url.rstrip("/") if base_url is not None else default_origin
        parts = validated_url(self.origin, "E_SPAPI_CONFIG", local_http=True)
        if parts.path or parts.query:
            raise SPAPIError("E_SPAPI_CONFIG", message="Endpoint override must be an origin")
        self.host = parts.netloc
        self.is_local = parts.hostname in LOOPBACK
        self.lwa_url = self.origin + "/auth/o2/token" if base_url is not None else LWA_URL
        self.opener = build_opener(NoRedirect())
        self.local_opener = build_opener(ProxyHandler({}), NoRedirect())
        self.access = None
        self.refresh_at = 0

    def request(self, make_request, deadline=None, *, retry_throttled=True):
        for fallback in (2, 4, 8, None) if retry_throttled else (None,):
            request = make_request()
            timeout = 30
            if deadline is not None:
                timeout = min(timeout, deadline - time.monotonic())
                if timeout <= 0:
                    raise SPAPIError("E_SPAPI_NET", message="Report polling deadline exceeded")
            opener = self.local_opener if urlsplit(request.full_url).hostname in LOOPBACK else self.opener
            try:
                with opener.open(request, timeout=timeout) as response:
                    body = response.read()
                    return body, response.headers
            except HTTPError as error:
                status = error.code
                retry_after = error.headers.get("Retry-After")
                error.close()
                if status == 429 and fallback is not None:
                    pause(retry_delay(retry_after, fallback), deadline)
                    continue
                code = {401: "E_SPAPI_AUTH", 403: "E_SPAPI_AUTH", 429: "E_SPAPI_THROTTLED"}
                raise SPAPIError(code.get(status, "E_SPAPI_HTTP"), status=status) from None
            except (OSError, http.client.HTTPException, ValueError):
                raise SPAPIError("E_SPAPI_NET", message="Request failed or timed out") from None

    def access_token(self, deadline, *, retry_throttled=True):
        now = time.monotonic()
        if now >= self.refresh_at:
            data = urlencode({"grant_type": "refresh_token", **self.credentials}).encode()
            request = Request(self.lwa_url, data=data, headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            })
            body, _ = self.request(lambda: request, deadline, retry_throttled=retry_throttled)
            result = object_data(body, "LWA")
            access = response_string(result, "access_token")
            expires = result.get("expires_in")
            if not re.fullmatch(r"[!-~]+", access) or type(expires) is not int or expires <= 0:
                raise SPAPIError("E_SPAPI_HTTP", message="Invalid LWA response")
            self.access = access
            self.refresh_at = now + expires - 60
        return self.access

    def api(self, method, path, params=(), payload=None, deadline=None):
        query = "&".join(f"{key}={value}" for key, value in sorted(
            (aws_encode(key), aws_encode(value)) for key, value in params
        ))
        url = self.origin + path + ("?" + query if query else "")
        body = json.dumps(payload).encode() if payload is not None else None

        def make_request():
            headers = sign_request(
                method, path, query, body or b"", self.host, self.region,
                self.credentials["client_id"], self.access_token(deadline)
            )
            headers["Accept"] = "application/json"
            if body is not None:
                headers["Content-Type"] = "application/json"
            return Request(url, data=body, headers=headers, method=method)

        data, _ = self.request(make_request, deadline)
        return object_data(data, "SP-API")

    def catalog(self, asin):
        return self.api("GET", f"/catalog/2022-04-01/items/{asin}", (
            ("marketplaceIds", self.market_id), ("includedData", "summaries,attributes")
        ))

    def report(self, report_type, days):
        end = datetime.now(timezone.utc).replace(microsecond=0)
        start = end - timedelta(days=days)
        created = self.api("POST", REPORTS + "/reports", payload={
            "reportType": report_type,
            "marketplaceIds": [self.market_id],
            "dataStartTime": start.isoformat(),
            "dataEndTime": end.isoformat(),
        })
        report_id = aws_encode(response_string(created, "reportId"))
        deadline = time.monotonic() + 300
        while True:
            report = self.api("GET", REPORTS + "/reports/" + report_id, deadline=deadline)
            if time.monotonic() >= deadline:
                raise SPAPIError("E_SPAPI_NET", message="Report polling deadline exceeded")
            status = report.get("processingStatus")
            if status == "DONE":
                break
            if status not in ("IN_QUEUE", "IN_PROGRESS"):
                message = status if status in ("FATAL", "CANCELLED") else "Invalid report status"
                raise SPAPIError("E_SPAPI_HTTP", message=message)
            pause(5, deadline)

        document_id = aws_encode(response_string(report, "reportDocumentId"))
        document = self.api("GET", REPORTS + "/documents/" + document_id)
        url = response_string(document, "url")
        validated_url(url, "E_SPAPI_HTTP", local_http=self.is_local)
        body, headers = self.request(lambda: Request(url))
        if (document.get("compressionAlgorithm") == "GZIP"
                or headers.get("Content-Encoding", "").lower() == "gzip"
                or body.startswith(b"\x1f\x8b")):
            try:
                body = gzip.decompress(body)
            except (OSError, EOFError, zlib.error):
                raise SPAPIError("E_SPAPI_HTTP", message="Invalid gzip report") from None
        data = json_data(body, "report document")
        if not isinstance(data, (dict, list)):
            raise SPAPIError("E_SPAPI_HTTP", message="Expected JSON report object or array")
        return data

    def save(self, path, data):
        serialized = json.dumps(data)
        summary_path = json.dumps(str(path))
        for value in (*self.sensitive_values, self.access):
            escaped_value = json.dumps(value)[1:-1]
            if escaped_value in serialized or escaped_value in summary_path:
                raise SPAPIError("E_SPAPI_HTTP", message="Credential material in output")

        temporary_path = None
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                             delete=False) as temporary:
                temporary_path = Path(temporary.name)
                temporary.write(serialized + "\n")
            temporary_path.replace(path)
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)


def report_count(data):
    if isinstance(data, list):
        return len(data)
    sections = [data.get(field) for field in ("salesAndTrafficByDate", "salesAndTrafficByAsin")]
    counts = [len(section) for section in sections if isinstance(section, list)]
    return sum(counts) if counts else int(bool(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    catalog = commands.add_parser("catalog", help="Fetch catalog summaries and attributes")
    catalog.add_argument("--asin", type=str.upper, required=True, help="Amazon ASIN")
    report = commands.add_parser("report", help="Create and download a JSON report")
    report.add_argument("--type", required=True, help="SP-API report type")
    report.add_argument("--days", type=int, required=True, help="Lookback period in days")
    for command in (catalog, report):
        command.add_argument("--marketplace", type=str.upper, default="US",
                             metavar="COUNTRY", help="Amazon marketplace country code (default: US)")
        command.add_argument("--out", type=Path, required=True, help="Output directory")
        command.add_argument("--base-url", help="Override both SP-API and LWA origins for testing")
    args = parser.parse_args()

    try:
        if args.marketplace not in MARKETPLACES:
            raise SPAPIError("E_SPAPI_CONFIG", message="Unsupported marketplace")
        client = SPAPI(args.marketplace, args.base_url)
        if args.command == "catalog":
            if not re.fullmatch(r"[A-Z0-9]{10}", args.asin):
                raise SPAPIError("E_SPAPI_CONFIG", message="ASIN must be ten letters or digits")
            data = client.catalog(args.asin)
            path = args.out / f"catalog-{args.asin}-{args.marketplace}.json"
            count = 1
        else:
            if not re.fullmatch(r"[A-Z0-9_]{1,120}", args.type):
                raise SPAPIError("E_SPAPI_CONFIG", message="Invalid report type")
            if not 1 <= args.days < datetime.now(timezone.utc).toordinal():
                raise SPAPIError("E_SPAPI_CONFIG", message="Invalid lookback period")
            data = client.report(args.type, args.days)
            path = args.out / f"report-{args.type}-{args.marketplace}-{args.days}d.json"
            count = report_count(data)
        client.save(path, data)
        print(json.dumps({"type": args.command, "items": count, "out": str(path)}))
        return 0
    except OSError:
        error = SPAPIError("E_SPAPI_IO", message="Unable to write output")
    except SPAPIError as caught:
        error = caught
    print(json.dumps({"code": error.code, **error.details}), file=sys.stderr)
    return EXIT_CODES[error.code]


if __name__ == "__main__":
    sys.exit(main())
