#!/usr/bin/env python3
"""Route a platform search through the connectors declared in its manifest."""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


SCRIPTS = Path(__file__).resolve().parent
DISTRIBUTION = SCRIPTS.parent.parent.parent
EBAY_ERRORS = {
    3: "E_EBAY_AUTH",
    4: "E_EBAY_THROTTLED",
    5: "E_EBAY_HTTP",
    6: "E_EBAY_NET",
}
T3_ERRORS = {2: "blocked", 3: "empty"}
CREDENTIAL_NAMES = {"EBAY_CLIENT_ID", "EBAY_CLIENT_SECRET", "GATEWAY_TOKEN"}


class ConfigError(Exception):
    pass


class RouterParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default diagnostic can echo sensitive command-line text.
        raise ConfigError("invalid_arguments")


def parse_args():
    parser = RouterParser(description=__doc__)
    run = parser.add_subparsers(dest="command", required=True).add_parser(
        "run", help="Run a manifest's search connectors in tier order"
    )
    run.add_argument("--platform", required=True, help="Platform manifest ID")
    run.add_argument("--need", required=True, choices=("search",), help="Fetch operation")
    run.add_argument("--q", required=True, help="Search keywords")
    run.add_argument("--site", default="EBAY_US", help="Marketplace ID (default: EBAY_US)")
    run.add_argument("--limit", type=int, default=20, help="Result limit (default: 20)")
    run.add_argument("--out", type=Path, default=Path("out"), help="Output directory (default: out)")
    run.add_argument("--manifest", type=Path, help="Use this manifest instead of automatic lookup")
    run.add_argument("--env", choices=("sandbox", "production"), default="sandbox",
                     help="eBay environment (default: sandbox)")
    run.add_argument("--base-url", help="Override the eBay API origin for local testing")
    run.add_argument("--t3-cmd", help="Replace the entire T3 command for testing (no shell)")
    return parser.parse_args()


def contains_credential(text, credentials):
    return any(value in text or json.dumps(value, ensure_ascii=False)[1:-1] in text
               for value in credentials)


def load_route(args):
    relative = Path("platforms") / args.platform / "manifest.json"
    paths = [args.manifest] if args.manifest is not None else [
        Path("95-engine") / relative, DISTRIBUTION / "l3" / relative,
    ]
    path = next((path for path in paths if path.is_file()), None)
    if path is None:
        raise ConfigError("manifest_not_found")
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
        connectors = manifest["connectors"]
        if not isinstance(connectors, list) or any(
            not isinstance(entry, dict)
            or not isinstance(entry.get("id"), str) or not entry["id"]
            or not isinstance(entry.get("tier"), str) or not entry["tier"]
            for entry in connectors
        ):
            raise ValueError
    except (OSError, ValueError, KeyError, TypeError, RecursionError):
        raise ConfigError("invalid_manifest") from None

    route = [("T1", entry["id"]) for entry in connectors
             if entry["tier"] == "T1" and entry["id"] != "browser-farm"]
    if any(entry["id"] == "browser-farm" for entry in connectors):
        route.append(("T3", "browser-farm"))
    return route


def run_ebay(args, temporary):
    script = SCRIPTS / "ebay_fetch.py"
    if not script.is_file():
        return {"status": "skipped", "reason": "ebay_unavailable"}, None
    command = [sys.executable, str(script), "search", f"--q={args.q}", f"--site={args.site}",
               f"--limit={args.limit}", f"--out={temporary}", f"--env={args.env}"]
    if args.base_url is not None:
        command.append(f"--base-url={args.base_url}")
    try:
        child = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return {"status": "skipped", "reason": "ebay_unavailable"}, None
    code = child.returncode
    if code == 2:
        return {"status": "skipped", "reason": "E_EBAY_CONFIG", "exit_code": code}, None
    if code != 0:
        return {"status": "failed", "code": EBAY_ERRORS.get(code, "E_EBAY_EXIT"),
                "exit_code": code}, None
    try:
        path, = temporary.glob("ebay_search_*.json")
        result = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(result, dict) or not isinstance(result.get("itemSummaries"), list):
            raise ValueError
    except (OSError, ValueError, RecursionError):
        return {"status": "failed", "code": "E_EBAY_HTTP", "reason": "invalid_result",
                "exit_code": code}, None
    return {"status": "ok", "exit_code": code}, result


def run_t3(args, temporary, override):
    command = override
    if command is None:
        probe = DISTRIBUTION / "connectors" / "farm-probe.js"
        if not probe.is_file():
            return {"status": "skipped", "reason": "t3_unavailable"}, None
        items_path = temporary / "items.jsonl"
        # Keep probe output in memory until it has passed the credential check.
        items_path.symlink_to(os.devnull)
        (temporary / "items.jsonl.meta.json").symlink_to(os.devnull)
        command = ["node", str(probe), "--platform", args.platform, "--query", args.q,
                   "--out", str(items_path)]
    try:
        child = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return {"status": "skipped", "reason": "t3_unavailable"}, None
    code = child.returncode
    if code != 0:
        return {"status": "failed", "reason": T3_ERRORS.get(code, "error"), "exit_code": code}, None
    # An exit-only test stub has no result. The real probe must report items.
    try:
        result = json.loads(child.stdout) if child.stdout.strip() else None
    except (ValueError, RecursionError):
        result = None
    if override is None:
        items = result.get("items") if isinstance(result, dict) else None
        if not isinstance(items, list) or not items or any(not isinstance(item, dict) for item in items):
            return {"status": "failed", "reason": "invalid_result", "exit_code": code}, None
        result = {"items": items}
    return {"status": "ok", "exit_code": code}, result


def route_search(args, route, override, credentials):
    tier_used, result = None, None
    attempts = []
    for tier, connector in route:
        attempt = {"tier": tier, "connector": connector}
        if contains_credential(connector, credentials):
            attempt["connector"] = "[redacted]"
        if tier_used is not None:
            details = {"status": "skipped", "reason": "not_needed"}
        elif tier == "T1" and connector != "ebay-api":
            details = {"status": "skipped", "reason": "connector_not_implemented"}
        else:
            with tempfile.TemporaryDirectory(prefix="fetch-router-") as temporary:
                if tier == "T1":
                    details, candidate = run_ebay(args, Path(temporary))
                else:
                    details, candidate = run_t3(args, Path(temporary), override)
            if details["status"] == "ok":
                if contains_credential(json.dumps(candidate, ensure_ascii=False), credentials):
                    details.update(status="failed", reason="credential_in_result")
                else:
                    tier_used, result = tier, candidate
        attempts.append({**attempt, **details})
    return tier_used, result, attempts


def main():
    credentials = {value for name, value in os.environ.items() if value
                   and (name in CREDENTIAL_NAMES or name.startswith("DSH_SECRET_"))}
    try:
        args = parse_args()
        if (not re.fullmatch(r"[a-z][a-z0-9_-]*", args.platform) or not args.q.strip()
                or not 1 <= args.limit <= 200):
            raise ConfigError("invalid_arguments")
        if any(contains_credential(str(value), credentials) for value in vars(args).values()):
            raise ConfigError("credential_in_arguments")
        try:
            if args.base_url is not None:
                origin = urlsplit(args.base_url)
                if origin.username is not None or origin.query or origin.fragment:
                    raise ConfigError("invalid_base_url")
            override = shlex.split(args.t3_cmd) if args.t3_cmd is not None else None
            if override == []:
                raise ValueError
        except ValueError:
            raise ConfigError("invalid_arguments") from None

        tier_used, result, attempts = route_search(args, load_route(args), override, credentials)
        if tier_used is None:
            print(json.dumps({"code": "E_NO_TIER", "attempts": attempts}), file=sys.stderr)
            return 7

        fallback = tier_used == "T3"
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = args.out / f"fetch_{args.platform}_{stamp}.json"
        summary = json.dumps({"tier_used": tier_used, "fallback": fallback, "out": str(path)},
                             ensure_ascii=False)
        data = {"platform": args.platform, "need": args.need,
                "args": {"q": args.q, "site": args.site, "limit": args.limit},
                "tier_used": tier_used, "fallback": fallback, "attempts": attempts, "result": result}
        content = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        if any(contains_credential(value, credentials) for value in (summary, content)):
            raise ConfigError("credential_in_output")
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".fetch-", dir=path.parent) as temporary:
            pending = Path(temporary) / path.name
            pending.write_text(content, encoding="utf-8")
            pending.replace(path)
        print(summary)
        return 0
    except ConfigError as error:
        reason = str(error)
    except (OSError, ValueError, RecursionError):
        reason = "io_error"
    print(json.dumps({"code": "E_ROUTER_CONFIG", "reason": reason}), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
