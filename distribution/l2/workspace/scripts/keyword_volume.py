#!/usr/bin/env python3
"""用 Amazon Brand Analytics 补全候选词的上个完整自然月搜索量。"""

import argparse
import calendar
import codecs
import csv
import io
import re
import shutil
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.dont_write_bytecode = True
from spapi_fetch import EXIT_CODES, MARKETPLACES, SPAPI, SPAPIError, json_data


REPORT_TYPE = "GET_BRAND_ANALYTICS_SEARCH_QUERY_PERFORMANCE_REPORT"
VOLUME = "月搜索量"
SOURCE = "月搜索量来源"
SOURCE_NAME = "SP-API Brand Analytics"
# 每个 ASIN 10 字符，加上分隔空格，每批最多 18 个才能满足 200 字符上限。
ASINS_PER_REPORT = 18


def read_candidates(path):
    raw = path.read_bytes()
    encoding = "utf-8-sig" if raw.startswith(codecs.BOM_UTF8) else "utf-8"
    reader = csv.DictReader(io.StringIO(raw.decode(encoding), newline=""), strict=True)
    fields = reader.fieldnames or []
    if len(fields) != len(set(fields)) or not {"关键词", "商品名"}.intersection(fields):
        raise ValueError("候选表须有「关键词」或「商品名」，表头不能重复")
    rows = list(reader)
    if any(None in row for row in rows):
        raise ValueError("候选行的列数超过表头")
    return fields, rows, encoding


def write_candidates(path, fields, rows, encoding):
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding=encoding, newline="", dir=path.parent,
                                         delete=False) as temporary:
            temporary_path = Path(temporary.name)
            writer = csv.DictWriter(temporary, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)
        if path.exists():
            shutil.copymode(path, temporary_path)
        temporary_path.replace(path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def previous_month():
    this_month = datetime.now(timezone.utc).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    end = this_month - timedelta(seconds=1)
    start = end.replace(day=1, hour=0, minute=0, second=0)
    return start, end


def fetch_reports(client, rows, requested_asins, period):
    supplied = requested_asins or [row.get("ASIN") or "" for row in rows]
    asins = list(dict.fromkeys(asin.strip().upper() for asin in supplied if asin.strip()))
    if not asins or any(not re.fullmatch(r"[A-Z0-9]{10}", asin) for asin in asins):
        raise SPAPIError("E_SPAPI_CONFIG", message="请用 --asin 或候选表 ASIN 列提供十位字母数字的授权品牌 ASIN")

    for offset in range(0, len(asins), ASINS_PER_REPORT):
        yield client.report_for_period(
            REPORT_TYPE, *period,
            options={"asin": " ".join(asins[offset:offset + ASINS_PER_REPORT]), "reportPeriod": "MONTH"},
        )


def check_month(start_value, end_value, expected):
    try:
        start = datetime.fromisoformat(start_value.replace("Z", "+00:00")).date()
        end = datetime.fromisoformat(end_value.replace("Z", "+00:00")).date()
    except (AttributeError, TypeError, ValueError):
        raise SPAPIError("E_SPAPI_HTTP", message="报表日期无效") from None
    if (start.day != 1 or (start.year, start.month) != (end.year, end.month)
            or end.day != calendar.monthrange(start.year, start.month)[1]
            or (expected is not None and (start, end) != expected)):
        raise SPAPIError("E_SPAPI_HTTP", message="报表日期与完整自然月不符")
    return start, end


def report_entries(report, market_id, period):
    if report == {} or report == []:
        return
    if not isinstance(report, dict) or not isinstance(report.get("dataByAsin"), list):
        raise SPAPIError("E_SPAPI_HTTP", message="Search Query Performance 报表缺少 dataByAsin 数组")
    if "reportSpecification" in report:
        spec = report["reportSpecification"]
        options = spec.get("reportOptions") if isinstance(spec, dict) else None
        if (not isinstance(options, dict) or options.get("reportPeriod") != "MONTH"
                or spec.get("reportType") != REPORT_TYPE or spec.get("marketplaceIds") != [market_id]):
            raise SPAPIError("E_SPAPI_HTTP", message="报表类型、月度粒度或市场与请求不符")
        if "dataStartTime" in spec or "dataEndTime" in spec:
            period = check_month(spec.get("dataStartTime"), spec.get("dataEndTime"), period)
    for entry in report["dataByAsin"]:
        if isinstance(entry, dict) and ("startDate" in entry or "endDate" in entry):
            period = check_month(entry.get("startDate"), entry.get("endDate"), period)
        yield entry


def query_volumes(reports, market_id, period):
    volumes = defaultdict(set)
    has_entries = False
    for report in reports:
        for entry in report_entries(report, market_id, period):
            has_entries = True
            query = entry.get("searchQueryData") if isinstance(entry, dict) else None
            if not isinstance(query, dict):
                continue
            term, volume = query.get("searchQuery"), query.get("searchQueryVolume")
            if isinstance(term, str) and term.strip() and type(volume) is int and volume > 0:
                volumes[term.strip().lower()].add(volume)

    if not has_entries:
        raise SPAPIError("E_SPAPI_EMPTY", message="Search Query Performance 报表为空")
    # 同一个词的 searchQueryVolume 是该词的总量，跨 ASIN 重复时不累加。
    return {term: next(iter(values)) for term, values in volumes.items() if len(values) == 1}


def fill_candidates(rows, volumes):
    updated = 0
    for row in rows:
        term = ((row.get("关键词") or "").strip() or (row.get("商品名") or "").strip()).lower()
        if term in volumes:
            row[VOLUME] = volumes[term]
            row[SOURCE] = SOURCE_NAME
            updated += 1
    if not updated:
        raise SPAPIError("E_SPAPI_EMPTY", message="候选关键词无匹配的有效月搜索量")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, required=True, help="候选 CSV，粗筛表以商品名作为关键词")
    parser.add_argument("--out", type=Path, help="另存为 CSV（默认就地更新）")
    parser.add_argument("--mock", type=Path, help="离线解析 Amazon 报表 JSON")
    parser.add_argument("--marketplace", type=str.upper, choices=MARKETPLACES, default="US", help="目标站点（默认 US）")
    parser.add_argument("--asin", action="append", default=[], help="已授权品牌的 ASIN，可重复（默认读取 ASIN 列）")
    args = parser.parse_args()

    try:
        client = None if args.mock else SPAPI(args.marketplace, None)
        fields, rows, encoding = read_candidates(args.candidates)
        if args.mock:
            reports = [json_data(args.mock.read_bytes(), "mock report")]
            expected_period = None
        else:
            period = previous_month()
            reports = fetch_reports(client, rows, args.asin, period)
            expected_period = tuple(day.date() for day in period)
        volumes = query_volumes(reports, MARKETPLACES[args.marketplace][1], expected_period)
        fill_candidates(rows, volumes)
        output_fields = list(dict.fromkeys([*fields, VOLUME, SOURCE]))
        write_candidates(args.out or args.candidates, output_fields, rows, encoding)
        return 0
    except SPAPIError as error:
        if error.details.get("missing"):
            print(f"{error.code} missing: {', '.join(error.details['missing'])}", file=sys.stderr)
        elif error.details.get("status") == 403 and error.request_source == "SP-API":
            print("E_SPAPI_ROLE HTTP 403，请检查 Brand Analytics 角色、Brand Registry 和卖家站点授权", file=sys.stderr)
        else:
            reason = error.details.get("message") or f"HTTP {error.details['status']}"
            if reason == "CANCELLED":
                reason = "Amazon 取消报表，可能没有可用数据"
            print(f"{error.code} {reason}", file=sys.stderr)
        return EXIT_CODES.get(error.code, 5)
    except (OSError, ValueError, csv.Error) as error:
        print(f"E_KEYWORD_VOLUME_IO {error}", file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main())
