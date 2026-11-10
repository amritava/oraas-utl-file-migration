#!/usr/bin/env python3
"""
Regression tests for scripts/oraas_convert.py --direction download.

    python tests/test_download_converter.py [--emit DIR]

Each case is a small PL/SQL unit plus the expected outcome. With --emit, the
generated sources are written to DIR so they can be syntax-checked.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "scripts"))
import oraas_convert as C  # noqa: E402

RULES = json.loads((ROOT / "config" / "download_rules.json").read_text())
RULES["manual_markers"] = ["MY_HANDOFF_PROC"]   # simulate a site that already uses a hand-off procedure
CONV = C.Converter(RULES)

CASES = []


def case(name, src, status, blocker=None, contains=(), absent=(), count=None, warns=()):
    CASES.append(dict(name=name, src=src, status=status, blocker=blocker, contains=contains,
                      absent=absent, count=count or {}, warns=warns))


# 1 -------------------------------------------------------------------------
case("early_return_no_handler", """
CREATE OR REPLACE PROCEDURE T1(PI_JOB_ID IN NUMBER, PI_BUS_DATE IN DATE, PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  PO_ERR_CODE := 0;
  f := UTL_FILE.FOPEN('DIR_A', 'a.txt', 'w');
  IF PI_JOB_ID IS NULL THEN
    UTL_FILE.FCLOSE(f);
    RETURN;
  END IF;
  UTL_FILE.PUT_LINE(f, 'x');
  UTL_FILE.FCLOSE(f);
END T1;
/
""", "CONVERTED",
     contains=["EXCEPTION  -- ORAAS (generated)", "oraas_utl.end_unit(l_oraas_frame, FALSE);",
               "p_business_date => TO_CHAR(PI_BUS_DATE, 'YYYY-MM-DD')",
               "oraas_utl.end_unit(l_oraas_frame, (PO_ERR_CODE IS NULL OR PO_ERR_CODE = 0));\n    RETURN;"],
     count={"oraas_utl.end_unit(": 3})

# 2 -------------------------------------------------------------------------
case("handler_raise_named_only", """
CREATE OR REPLACE PROCEDURE T2(PO_STATUS_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
  e_bad EXCEPTION;
BEGIN
  f := UTL_FILE.FOPEN('DIR_A', 'b.txt', 'W', 32767);
  UTL_FILE.PUT_LINE(f, 'x');
  UTL_FILE.FCLOSE(f);
EXCEPTION
  WHEN e_bad THEN
    BEGIN
      RAISE NO_DATA_FOUND;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    CASE WHEN 1 = 1 THEN PO_STATUS_CODE := 1; ELSE NULL; END CASE;
    RAISE_APPLICATION_ERROR(-20001, 'bad');
  WHEN NO_DATA_FOUND THEN
    PO_STATUS_CODE := -1;
    RAISE;
END;
/
""", "CONVERTED",
     contains=["WHEN OTHERS THEN  -- ORAAS (generated)"],
     count={"oraas_utl.end_unit(l_oraas_frame, FALSE);": 3,
            "(PO_STATUS_CODE IS NULL OR PO_STATUS_CODE = 0)": 1})

# 3 -------------------------------------------------------------------------
case("package_body_two_subprograms", """
CREATE OR REPLACE PACKAGE BODY PKG_T3 IS
  g_count NUMBER := 0;
  PROCEDURE w(fh IN UTL_FILE.FILE_TYPE, s IN VARCHAR2);
  PROCEDURE w(fh IN UTL_FILE.FILE_TYPE, s IN VARCHAR2) IS
  BEGIN
    UTL_FILE.PUT_LINE(fh, s);
  END w;
  PROCEDURE run(PI_JOB_ID IN NUMBER, PO_ERR_CODE OUT NUMBER) IS
    f UTL_FILE.FILE_TYPE;
  BEGIN
    f := UTL_FILE.FOPEN('DIR_A', 'c.txt', 'w');
    w(f, 'hello');
    UTL_FILE.FCLOSE(f);
  EXCEPTION
    WHEN OTHERS THEN
      PO_ERR_CODE := -1;
  END run;
  FUNCTION unrelated RETURN NUMBER IS
  BEGIN
    RETURN 1;
  END;
END PKG_T3;
/
""", "CONVERTED_WITH_WARNINGS",
     contains=["p_unit_name => 'PKG_T3.RUN'", "PROCEDURE w(fh IN ORAAS_UTL.FILE_TYPE"],
     count={"oraas_utl.begin_unit(": 1, "oraas_utl.end_unit(": 2},
     warns=["PUBLIC_HANDLE_PARAMETER"])

case("package_level_handle", """
CREATE OR REPLACE PACKAGE BODY PKG_T3B IS
  g_f UTL_FILE.FILE_TYPE;
  PROCEDURE o IS BEGIN g_f := UTL_FILE.FOPEN('D','x','w'); END;
END;
/
""", "REVIEW_REQUIRED", blocker="PACKAGE_LEVEL_HANDLE")

# 4 -------------------------------------------------------------------------
case("read_mode_upload", """
CREATE OR REPLACE PROCEDURE T4 IS
  f UTL_FILE.FILE_TYPE; l VARCHAR2(100);
BEGIN
  f := UTL_FILE.FOPEN('D', 'in.txt', 'r');
  UTL_FILE.GET_LINE(f, l);
  UTL_FILE.FCLOSE(f);
END;
/
""", "UPLOAD_SCOPE", blocker="UPLOAD_SCOPE")

# 5 -------------------------------------------------------------------------
case("dynamic_sql_literal", """
CREATE OR REPLACE PROCEDURE T5(PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  f := UTL_FILE.FOPEN('D', 'd.txt', 'w');
  EXECUTE IMMEDIATE 'BEGIN UTL_FILE.FCLOSE_ALL; END;';
  PO_ERR_CODE := 0;
EXCEPTION WHEN UTL_FILE.WRITE_ERROR THEN
  PO_ERR_CODE := 1;
  DBMS_OUTPUT.PUT_LINE('UTL_FILE write failed');
END;
/
""", "CONVERTED_WITH_WARNINGS",
     contains=["'BEGIN ORAAS_UTL.FCLOSE_ALL; END;'", "'UTL_FILE write failed'"],
     warns=["DYNAMIC_SQL_REWRITTEN"])

# 6 -------------------------------------------------------------------------
case("sys_qualified_lowercase", """
create or replace procedure t6 is
  f sys.utl_file.file_type;
begin
  f := sys.utl_file.fopen('D', 'e.txt', 'w');
  utl_file.put(f, 'abc');
  utl_file.fclose(f);
end;
/
""", "CONVERTED_WITH_WARNINGS",
     contains=["f oraas_utl.file_type;", "f := oraas_utl.fopen("], absent=["sys.oraas_utl", "utl_file"],
     warns=["STATUS_UNGATED"])

# 7 -------------------------------------------------------------------------
case("fopen_in_declaration", """
CREATE OR REPLACE PROCEDURE T7 IS
  f UTL_FILE.FILE_TYPE := UTL_FILE.FOPEN('D', 'f.txt', 'w');
BEGIN
  UTL_FILE.FCLOSE(f);
END;
/
""", "REVIEW_REQUIRED", blocker="OPEN_IN_DECLARATION")

# 8 -------------------------------------------------------------------------
case("bfilename_dependency", """
CREATE OR REPLACE PROCEDURE T8 IS
  f UTL_FILE.FILE_TYPE; b BFILE := BFILENAME('D', 'x');
BEGIN
  f := UTL_FILE.FOPEN('D', 'g.txt', 'w'); UTL_FILE.FCLOSE(f);
END;
/
""", "REVIEW_REQUIRED", blocker="DIRECTORY_DEPENDENCY")

# 9 -------------------------------------------------------------------------
case("function_returns_handle", """
CREATE OR REPLACE FUNCTION T9 RETURN UTL_FILE.FILE_TYPE IS
BEGIN
  RETURN UTL_FILE.FOPEN('D', 'h.txt', 'w');
END;
/
""", "REVIEW_REQUIRED", blocker="HANDLE_ESCAPES_FRAME")

# 10 ------------------------------------------------------------------------
case("two_status_params", """
CREATE OR REPLACE PROCEDURE T10(PO_ERR_CODE OUT NUMBER, PO_STATUS_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  f := UTL_FILE.FOPEN('D', 'i.txt', 'w'); UTL_FILE.FCLOSE(f);
END;
/
""", "REVIEW_REQUIRED", blocker="AMBIGUOUS_STATUS")

# 11 ------------------------------------------------------------------------
case("varchar_status", """
CREATE OR REPLACE PROCEDURE T11(PO_STATUS_CODE OUT VARCHAR2) IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  f := UTL_FILE.FOPEN('D', 'j.txt', 'w'); UTL_FILE.FCLOSE(f);
END;
/
""", "REVIEW_REQUIRED", blocker="STATUS_NOT_NUMERIC")

# 12 ------------------------------------------------------------------------
case("already_converted", "-- ORAAS_UTL_DOWNLOAD_GENERATED v1\nCREATE PROCEDURE X IS BEGIN NULL; END;\n",
     "ALREADY_CONVERTED")

# 13 ------------------------------------------------------------------------
case("declare_block_nested_function", """
CREATE OR REPLACE PROCEDURE T13(PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  DECLARE
    FUNCTION g RETURN VARCHAR2 IS
    BEGIN
      RETURN 'x';
    END;
    CURSOR c RETURN dual%ROWTYPE IS SELECT * FROM dual;
  BEGIN
    f := UTL_FILE.FOPEN('D', 'k.txt', 'w');
    UTL_FILE.PUT_LINE(f, g);
    FOR r IN (SELECT CASE WHEN 1 = 1 THEN 'a' ELSE 'b' END AS v FROM dual) LOOP
      UTL_FILE.PUTF(f, '%s\\n', r.v);
    END LOOP;
    UTL_FILE.FCLOSE(f);
  END;
END;
/
""", "CONVERTED", count={"oraas_utl.end_unit(": 2},
     contains=["      RETURN 'x';"], absent=["end_unit(l_oraas_frame, (PO_ERR_CODE IS NULL OR PO_ERR_CODE = 0));\n      RETURN 'x'"])

# 14 ------------------------------------------------------------------------
case("append_mode_and_q_quote", """
CREATE OR REPLACE PROCEDURE T14(PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
  s VARCHAR2(100) := q'[it's END; UTL_FILE]';
BEGIN
  f := UTL_FILE.FOPEN('D', 'l.txt', 'a');
  UTL_FILE.PUT_LINE(f, s);
  UTL_FILE.FCLOSE(f);
END;
/
""", "CONVERTED_WITH_WARNINGS", warns=["APPEND_MODE"], contains=["q'[it's END; UTL_FILE]'"])

# 15 ------------------------------------------------------------------------
case("function_unit", """
CREATE OR REPLACE FUNCTION T15(PI_JOB_ID IN NUMBER) RETURN NUMBER IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  f := UTL_FILE.FOPEN('D', 'm.txt', 'w');
  UTL_FILE.FCLOSE(f);
  RETURN 1;
EXCEPTION
  WHEN OTHERS THEN
    RETURN -1;
END;
/
""", "CONVERTED_WITH_WARNINGS", warns=["FUNCTION_UNIT", "STATUS_UNGATED"],
     contains=["oraas_utl.end_unit(l_oraas_frame, TRUE);\n  RETURN 1;"])

# 16 ------------------------------------------------------------------------
case("mixed_helper", """
CREATE OR REPLACE PROCEDURE T16 IS
  f UTL_FILE.FILE_TYPE;
BEGIN
  f := UTL_FILE.FOPEN('D', 'n.txt', 'w'); UTL_FILE.FCLOSE(f);
  MY_HANDOFF_PROC(NULL);
END;
/
""", "REVIEW_REQUIRED", blocker="MIXED_CONVERSION")

# 17 ------------------------------------------------------------------------
case("no_utl_file", "CREATE OR REPLACE PROCEDURE T17 IS BEGIN NULL; END;\n/\n", "NO_UTL_FILE")

# 18 ------------------------------------------------------------------------
case("byte_mode", """
CREATE OR REPLACE PROCEDURE T18 IS f UTL_FILE.FILE_TYPE;
BEGIN f := UTL_FILE.FOPEN('D', 'o.bin', 'wb', 32767); UTL_FILE.FCLOSE(f); END;
/
""", "REVIEW_REQUIRED", blocker="BYTE_MODE")

# 19 ------------------------------------------------------------------------
case("handle_param_only_unit", """
CREATE OR REPLACE PROCEDURE T19(fh IN UTL_FILE.FILE_TYPE, s IN VARCHAR2) IS
BEGIN
  UTL_FILE.PUT_LINE(fh, s);
END;
/
""", "CONVERTED_WITH_WARNINGS", warns=["PUBLIC_HANDLE_PARAMETER"], absent=["begin_unit", "end_unit"])

# 20 ------------------------------------------------------------------------
case("conditional_compilation", """
CREATE OR REPLACE PROCEDURE T20 IS f UTL_FILE.FILE_TYPE;
BEGIN
  $IF DBMS_DB_VERSION.VER_LE_11 $THEN NULL; $END
  f := UTL_FILE.FOPEN('D','p','w'); UTL_FILE.FCLOSE(f);
END;
/
""", "REVIEW_REQUIRED", blocker="CONDITIONAL_COMPILATION")

# 21 ------------------------------------------------------------------------
case("crlf_and_inline_end", "CREATE OR REPLACE PROCEDURE T21(PO_ERR_CODE OUT NUMBER) IS\r\n  f UTL_FILE.FILE_TYPE;\r\n"
     "BEGIN f := UTL_FILE.FOPEN('D','q','w'); UTL_FILE.FCLOSE(f); END;\r\n/\r\n",
     "CONVERTED", absent=["\r\r", "\n\n\n"])


def run(emit=None):
    failures = 0
    for c in CASES:
        errs = []
        try:
            out, rep = CONV.convert(c["src"])
            status = rep["status"]
            blk = None
            warns = {f.code for f in rep["findings"] if f.level == "WARN"}
        except C.ReviewRequired as e:
            out, status, blk, warns = None, ("UPLOAD_SCOPE" if e.code == "UPLOAD_SCOPE" else "REVIEW_REQUIRED"), e.code, set()
        if status != c["status"]:
            errs.append(f"status {status} != {c['status']}" + (f" ({blk})" if blk else ""))
        if c["blocker"] and blk != c["blocker"]:
            errs.append(f"blocker {blk} != {c['blocker']}")
        norm = (out or "").replace("\r\n", "\n") if "\r" not in "".join(c["contains"]) else (out or "")
        for s in c["contains"]:
            if s not in norm:
                errs.append(f"missing: {s!r}")
        for s in c["absent"]:
            if s in (out or ""):
                errs.append(f"unexpected: {s!r}")
        for s, n in c["count"].items():
            k = norm.count(s)
            if k != n:
                errs.append(f"count {s!r} = {k}, expected {n}")
        for w in c["warns"]:
            if w not in warns:
                errs.append(f"warning {w} not raised (got {sorted(warns)})")
        if out and emit:
            Path(emit).mkdir(parents=True, exist_ok=True)
            (Path(emit) / f"{c['name']}.sql").write_text(out, newline="")
        print(("PASS " if not errs else "FAIL ") + c["name"] + ("" if not errs else "\n     " + "\n     ".join(errs)))
        failures += bool(errs)
    print(f"\n{len(CASES) - failures}/{len(CASES)} passed")
    return failures


if __name__ == "__main__":
    emit = sys.argv[sys.argv.index("--emit") + 1] if "--emit" in sys.argv else None
    sys.exit(1 if run(emit) else 0)
