#!/usr/bin/env python3
"""
Golden-file comparison: files written by the legacy unit (UTL_FILE on the old
database) versus files delivered from ORAAS_FILE_OUT by your adapter, for the
same business date and data.

    python oraas_golden_compare.py --legacy LEGACY_DIR --oraas ORAAS_DIR [--mask REGEX ...] [--report out.csv]

Files are paired by relative path. Use --mask for values that legitimately differ
between runs (generation time, sequence numbers), e.g.
    --mask "<file_time>\\d{6}</file_time>" --mask "<file_date>\\d{8}</file_date>"
Masks are applied to both sides before comparing; the raw SHA-256 is reported too.

Exit code 0 only if every pair matches.
"""
import argparse
import csv
import hashlib
import re
import sys
from pathlib import Path


def describe(b: bytes):
    return {
        "bytes": len(b),
        "bom": b.startswith(b"\xef\xbb\xbf"),
        "crlf": b.count(b"\r\n"),
        "lf": b.count(b"\n"),
        "ends_lf": b.endswith(b"\n"),
        "utf8": _is_utf8(b),
    }


def _is_utf8(b):
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def first_diff(a: bytes, b: bytes):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n if len(a) != len(b) else None


def position(b: bytes, off: int):
    line = b.count(b"\n", 0, off) + 1
    col = off - (b.rfind(b"\n", 0, off) + 1) + 1
    return line, col


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--legacy", type=Path, required=True)
    ap.add_argument("--oraas", type=Path, required=True)
    ap.add_argument("--mask", action="append", default=[], help="regex replaced by <MASK> on both sides")
    ap.add_argument("--report", type=Path, default=Path("golden_compare.csv"))
    a = ap.parse_args(argv)

    masks = [re.compile(m.encode("utf-8")) for m in a.mask]
    left = {p.relative_to(a.legacy): p for p in a.legacy.rglob("*") if p.is_file()}
    right = {p.relative_to(a.oraas): p for p in a.oraas.rglob("*") if p.is_file()}
    rows, bad = [], 0
    for rel in sorted(set(left) | set(right), key=str):
        row = {"file": str(rel)}
        if rel not in right:
            row["result"] = "MISSING_IN_ORAAS"
        elif rel not in left:
            row["result"] = "EXTRA_IN_ORAAS"
        else:
            lb, rb = left[rel].read_bytes(), right[rel].read_bytes()
            dl, dr = describe(lb), describe(rb)
            row.update({"legacy_sha256": hashlib.sha256(lb).hexdigest(),
                        "oraas_sha256": hashlib.sha256(rb).hexdigest(),
                        "legacy_bytes": dl["bytes"], "oraas_bytes": dr["bytes"]})
            ml, mr = lb, rb
            for m in masks:
                ml, mr = m.sub(b"<MASK>", ml), m.sub(b"<MASK>", mr)
            off = first_diff(ml, mr)
            if lb == rb:
                row["result"] = "MATCH"
            elif off is None:
                row["result"] = "MATCH_MASKED"
            else:
                line, col = position(ml, off)
                hints = []
                for k in ("bom", "crlf", "ends_lf", "utf8"):
                    if dl[k] != dr[k]:
                        hints.append(f"{k}: legacy={dl[k]} oraas={dr[k]}")
                if dl["lf"] != dr["lf"]:
                    hints.append(f"line feeds: legacy={dl['lf']} oraas={dr['lf']}")
                row.update({"result": "DIFF", "first_diff_offset": off, "line": line, "col": col,
                            "legacy_context": ml[max(0, off - 20):off + 20].decode("utf-8", "replace"),
                            "oraas_context": mr[max(0, off - 20):off + 20].decode("utf-8", "replace"),
                            "hints": "; ".join(hints)})
        bad += row["result"] not in ("MATCH", "MATCH_MASKED")
        rows.append(row)
        print(f"{row['result']:<17} {rel}" + (f"  line {row.get('line')} col {row.get('col')}  {row.get('hints', '')}"
                                               if row["result"] == "DIFF" else ""))
    fields = ["file", "result", "legacy_bytes", "oraas_bytes", "first_diff_offset", "line", "col",
              "hints", "legacy_context", "oraas_context", "legacy_sha256", "oraas_sha256"]
    with a.report.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"\n{len(rows) - bad}/{len(rows)} match. Report: {a.report}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
