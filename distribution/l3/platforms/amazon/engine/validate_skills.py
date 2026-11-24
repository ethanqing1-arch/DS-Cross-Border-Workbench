#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 skills/ 下所有 SKILL.md 是否符合 SKILL_SPEC.md。
用法：python3 engine/validate_skills.py [--strict]
退出码：0 全通过；1 有 ERROR（--strict 时 WARN 也算失败）。"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED_SECTIONS = ["何时用", "输入契约", "执行流程", "判定口径", "输出契约", "质检清单", "反模式"]
REQUIRED_FM = ["name", "description", "layer", "version", "inputs", "outputs"]
PLACEHOLDER = re.compile(r"(\bxxx\b|\bXXX\b|\bTODO\b|待补充|placeholder|FIXME|待填)", re.I)


def parse_fm(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    fm_raw, body = text[3:end], text[end + 4:]
    fm: dict[str, str] = {}
    for line in fm_raw.strip().splitlines():
        if ":" in line and not line.startswith((" ", "-", "\t")):
            k, v = line.split(":", 1)
            fm[k.strip()] = v.strip()
    return fm, body


def check(path: Path) -> tuple[list[str], list[str]]:
    errs, warns = [], []
    text = path.read_text(encoding="utf-8")
    fm, body = parse_fm(text)
    rel = path.relative_to(ROOT)
    if not fm:
        errs.append("缺少 YAML frontmatter")
        return errs, warns

    for k in REQUIRED_FM:
        if k not in fm or not fm[k]:
            errs.append(f"frontmatter 缺字段 {k}")

    dir_name = path.parent.name
    if fm.get("name") != dir_name:
        errs.append(f"name({fm.get('name')}) != 目录名({dir_name})")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", fm.get("name", "")):
        errs.append(f"name 不是小写连字符：{fm.get('name')}")

    layer_dir = path.parent.parent.name
    if fm.get("layer") != layer_dir:
        errs.append(f"layer({fm.get('layer')}) != 所在目录({layer_dir})")

    desc = fm.get("description", "")
    if len(desc) < 30:
        warns.append(f"description 偏短({len(desc)}字)，触发词不足")
    if "「" not in desc and "当用户" not in desc:
        warns.append("description 没写触发词（应出现「…」或'当用户…'）")

    for sec in REQUIRED_SECTIONS:
        if f"## {sec}" not in body:
            errs.append(f"缺小节：## {sec}")

    n = text.count("\n") + 1
    if n < 100:
        errs.append(f"行数 {n} < 100（内容过薄）")
    elif n > 260:
        warns.append(f"行数 {n} > 260（应外链 references/）")

    if PLACEHOLDER.search(text):
        errs.append(f"出现占位符：{PLACEHOLDER.search(text).group(0)}")

    # 每个阈值表至少出现 2 个数字，防止通篇定形容词
    if len(re.findall(r"\d+(?:\.\d+)?%?", body)) < 15:
        warns.append("正文数字 <15 个，可能阈值不清")
    return errs, warns


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()
    files = sorted(ROOT.glob("skills/*/*/SKILL.md"))
    if not files:
        print("没有找到任何 SKILL.md", file=sys.stderr)
        return 1
    bad = 0
    print(f"校验 {len(files)} 个 SKILL.md\n")
    for f in files:
        errs, warns = check(f)
        status = "FAIL" if errs else ("WARN" if warns else "OK  ")
        print(f"[{status}] {f.relative_to(ROOT)}  ({f.read_text(encoding='utf-8').count(chr(10))+1} 行)")
        for e in errs:
            print(f"       ✗ {e}")
        for w in warns:
            print(f"       ! {w}")
        if errs or (a.strict and warns):
            bad += 1
    print(f"\n结果：{len(files) - bad} 通过 / {bad} 有问题")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
