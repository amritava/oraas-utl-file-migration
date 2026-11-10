#!/usr/bin/env python3
"""
Refuse to publish if any forbidden word appears in the repository or in a
.skill/.zip package.

    python scripts/leak_check.py --denylist ~/private/oraas_denylist.txt [PATHS...]

The deny list is YOUR private file and must never be committed: one word per line
(matched as plain text), or re:<regular expression> (table, procedure, schema, product, company,
country or person names of the system you migrated). Lines starting with # are
comments. Matching is case-insensitive. Binary files and archives (.docx,
.skill, .zip) are scanned inside, including document metadata.

Exit code 0 = clean, 1 = forbidden word found, 2 = usage error.
Use it as a git pre-commit hook (see references/publishing.md).
"""
import argparse
import re
import sys
import zipfile
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "__pycache__", "gen", "g4"}


def load_patterns(path):
    pats = []
    for raw in Path(path).expanduser().read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            pats.append((line, re.compile(line[3:] if line.startswith("re:") else re.escape(line), re.I)))
    return pats


def scan_text(name, text, pats, hits):
    for n, line in enumerate(text.splitlines(), 1):
        for word, rx in pats:
            if rx.search(line):
                hits.append(f"{name}:{n}: '{word}' in: {line.strip()[:160]}")


def scan_bytes(name, data, pats, hits):
    if data[:4] == b"PK\x03\x04":
        import io
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for info in z.infolist():
                    if not info.is_dir():
                        scan_bytes(f"{name}!{info.filename}", z.read(info), pats, hits)
            return
        except zipfile.BadZipFile:
            pass
    scan_text(name, data.decode("utf-8", "replace"), pats, hits)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--denylist", required=True, help="private file with forbidden words (never commit it)")
    ap.add_argument("paths", nargs="*", default=["."])
    a = ap.parse_args(argv)
    dl = Path(a.denylist).expanduser()
    if not dl.is_file():
        print(f"Deny list not found: {dl}")
        return 2
    pats = load_patterns(dl)
    if not pats:
        print("Deny list is empty")
        return 2
    hits, files = [], 0
    for p in map(Path, a.paths):
        items = [p] if p.is_file() else [f for f in p.rglob("*")
                                         if f.is_file() and not (set(f.parts) & SKIP_DIRS)]
        for f in items:
            if f.resolve() == dl.resolve():
                continue
            files += 1
            scan_text(str(f), str(f), pats, hits)          # file names count too
            scan_bytes(str(f), f.read_bytes(), pats, hits)
    for h in hits:
        print("LEAK", h)
    print(f"{files} file(s) scanned, {len(hits)} finding(s), {len(pats)} pattern(s)")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
