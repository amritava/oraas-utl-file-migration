#!/usr/bin/env python3
"""Converts examples/download and examples/upload and compares with examples/expected."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import oraas_convert as C  # noqa: E402


def first_line_free(text):
    return text.split("\n", 1)[1] if "\n" in text else text


def run():
    bad = 0
    jobs = [("download", ROOT / "config" / "download_rules.json"),
            ("upload", ROOT / "examples" / "upload_rules.example.json")]
    for direction, rules in jobs:
        conv = C.Converter(json.loads(rules.read_text()))
        for src in sorted((ROOT / "examples" / direction).glob("*.prc")):
            out, _ = conv.convert(src.read_text())
            exp = (ROOT / "examples" / "expected" / direction / f"{src.stem}_MIG{src.suffix}").read_text()
            ok = out is not None and first_line_free(out) == first_line_free(exp)
            print(("PASS " if ok else "FAIL ") + f"{direction}/{src.name}")
            bad += not ok
    return bad


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
