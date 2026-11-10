#!/usr/bin/env python3
"""
Builds dist/oraas-utl-file-migration.skill (a zip with the skill folder at its top level).

    python scripts/package_skill.py [--denylist ~/private/oraas_denylist.txt]

With --denylist the package is leak-checked and deleted if anything is found.
"""
import argparse
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NAME = "oraas-utl-file-migration"
INCLUDE = ["SKILL.md", "README.md", "LICENSE", "CHANGELOG.md", "plsql", "scripts", "config",
           "references", "examples", "tests", "tools/plsql_syntax_check/check.ts",
           "tools/plsql_syntax_check/setup.sh", "hooks"]
SKIP = {"__pycache__", "node_modules", "gen", "g4", ".git"}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--denylist")
    a = ap.parse_args(argv)
    out = ROOT / "dist" / f"{NAME}.skill"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for item in INCLUDE:
            p = ROOT / item
            files = [p] if p.is_file() else sorted(f for f in p.rglob("*") if f.is_file())
            for f in files:
                if set(f.relative_to(ROOT).parts) & SKIP or f.suffix == ".pyc":
                    continue
                z.write(f, f"{NAME}/{f.relative_to(ROOT).as_posix()}")
    print(f"written {out} ({out.stat().st_size} bytes)")
    if a.denylist:
        rc = subprocess.call([sys.executable, str(ROOT / "scripts" / "leak_check.py"),
                              "--denylist", a.denylist, str(out)])
        if rc:
            out.unlink()
            print("package removed: leak check failed")
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
