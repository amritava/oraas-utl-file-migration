#!/usr/bin/env python3
"""
Regression tests for scripts/oraas_convert.py --direction upload.

    python tests/test_upload_converter.py [--emit DIR]
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "scripts"))
import oraas_convert as C  # noqa: E402

RULES = json.loads((ROOT / "config" / "upload_rules.json").read_text())
RULES["frame_trigger_calls"] = ["MY_DIR_LIST_PROC"]          # the invented listing procedure
RULES["manual_markers"] = ["MY_RAW_UPLOAD_TABLE", "MY_STAGING_TABLE"]   # simulate hand-migrated units
CONV = C.Converter(RULES)
INPUT = ROOT / "examples" / "upload"
CASES = []


def case(name, src, status, blocker=None, contains=(), absent=(), count=None, warns=(), nowarns=()):
    CASES.append(dict(name=name, src=src, status=status, blocker=blocker, contains=contains,
                      absent=absent, count=count or {}, warns=warns, nowarns=nowarns))


def real(fname):
    return (INPUT / fname).read_bytes().decode("utf-8")


# --- invented examples (examples/upload) -------------------------------------------
case("payment_example", real("PAYMENT_FILE_IMPORT.prc"), "CONVERTED_WITH_WARNINGS",
     contains=["ORAAS_UTL.GET_LINE(fh, l_line);", "ORAAS_UTL.FRENAME(src_location => ls_inbox",
               "p_unit_name     => 'PAYMENT_FILE_IMPORT'", "my_dir_list_proc(ls_inbox);",
               "v_session_id := pi_session_id;  --ORAAS Migration",
               "pi_session_id IN NUMBER DEFAULT NULL /* ORAAS Migration */) IS"],
     absent=["UTL_FILE."], nowarns=["NO_DISPOSITION", "IMPLICIT_CLOSE"],
     warns=["SESSION_VAR_SIZE"], count={"oraas_utl.mark_input(": 4})

case("customer_feed_example", real("CUSTOMER_FEED_LOAD.prc"), "CONVERTED_WITH_WARNINGS",
     contains=["ORAAS_UTL.GET_LINE(infile, buf);", "ORAAS_UTL.FCOPY(ls_inbox, lv_feed_file, ls_rejected, lv_feed_file);",
               "(TRIM(po_error_code) IS NULL OR TRIM(po_error_code) = '0')",
               "NVL(v_feed_failed, 'N') <> 'Y'"],
     absent=["UTL_FILE."], warns=["STATUS_CHAR"])

case("rate_reload_example", real("RATE_TABLE_RELOAD.prc"), "CONVERTED_WITH_WARNINGS",
     contains=["ORAAS_UTL.PUT_LINE(frej, l);", "PROCEDURE rate_table_reload (\n    po_status_code OUT NUMBER,"],
     warns=["NO_DISPOSITION", "READER_WITHOUT_LISTING"])

# --- synthetic ----------------------------------------------------------------
BASE = """
CREATE OR REPLACE PROCEDURE UP_T{n}(PI_BUS_DATE IN VARCHAR2, PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE;
  l VARCHAR2(4000);
  CURSOR c IS SELECT filename FROM my_dir_list_table WHERE issubdir = 'N';
BEGIN
  DELETE FROM my_dir_list_table;
  {listing}
  FOR r IN c LOOP
    f := UTL_FILE.FOPEN('INBOX', r.filename, {mode});
    LOOP
      BEGIN
        UTL_FILE.{getline}(f, l);
      EXCEPTION WHEN NO_DATA_FOUND THEN EXIT;
      END;
      INSERT INTO t VALUES (l);
    END LOOP;
    UTL_FILE.FCLOSE(f);
    {move}
  END LOOP;
END;
/
"""


def base(n, listing="My_Dir_List_Proc('/in');", mode="'r'", getline="GET_LINE",
         move="UTL_FILE.FRENAME('INBOX', r.filename, 'DONE_DIR', r.filename, TRUE);"):
    return BASE.format(n=n, listing=listing, mode=mode, getline=getline, move=move)


case("basic_reader", base(1), "CONVERTED",
     contains=["ORAAS_UTL.GET_LINE(f, l);", "oraas_utl.end_unit(l_oraas_frame, FALSE);"],
     count={"oraas_utl.begin_unit(": 1})
case("binary_read", base(2, getline="GET_RAW"), "REVIEW_REQUIRED", blocker="BYTE_MODE")
case("rb_mode", base(3, mode="'rb'"), "REVIEW_REQUIRED", blocker="BYTE_MODE")
case("fseek", base(4, move="UTL_FILE.FSEEK(f, 0);"), "REVIEW_REQUIRED", blocker="BYTE_MODE")
case("no_disposition", base(5, move="NULL;"), "CONVERTED_WITH_WARNINGS", warns=["NO_DISPOSITION"])
case("reader_without_listing", base(6, listing="NULL;"), "CONVERTED_WITH_WARNINGS",
     warns=["READER_WITHOUT_LISTING"])
case("fcopy_fremove_move", base(7, move="UTL_FILE.FCOPY('INBOX', r.filename, 'ERR_DIR', r.filename); "
                                      "UTL_FILE.FREMOVE('INBOX', r.filename);"),
     "CONVERTED", nowarns=["EXTERNAL_FCOPY", "EXTERNAL_FREMOVE"])

case("listing_only_no_utl_file", """
CREATE OR REPLACE PROCEDURE UP_LIST(PO_ERR_CODE OUT NUMBER) IS
BEGIN
  DELETE FROM my_dir_list_table;
  MY_DIR_LIST_PROC('/in');
  UP_READER;
END;
/
""", "CONVERTED_WITH_WARNINGS", warns=["LISTING_WITHOUT_READER"], count={"oraas_utl.begin_unit(": 1})

case("reads_and_writes_reject_file", """
CREATE OR REPLACE PROCEDURE UP_RW(PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE; o UTL_FILE.FILE_TYPE; l VARCHAR2(4000);
BEGIN
  MY_DIR_LIST_PROC('/in');
  f := UTL_FILE.FOPEN('INBOX', 'a.csv', 'R');
  o := UTL_FILE.FOPEN('OUTBOX', 'a.rej', 'W');
  BEGIN
    LOOP UTL_FILE.GET_LINE(f, l); UTL_FILE.PUT_LINE(o, l); END LOOP;
  EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
  END;
  UTL_FILE.FCLOSE(f);
  UTL_FILE.FCLOSE(o);
  UTL_FILE.FRENAME('INBOX', 'a.csv', 'ERROR_DIR', 'a.csv');
END;
/
""", "CONVERTED", contains=["ORAAS_UTL.PUT_LINE(o, l);", "(PO_ERR_CODE IS NULL OR PO_ERR_CODE = 0)"])

case("reader_never_closes_no_implicit_warning", base(9, move="NULL;").replace("    UTL_FILE.FCLOSE(f);\n", ""),
     "CONVERTED_WITH_WARNINGS", nowarns=["IMPLICIT_CLOSE"], warns=["NO_DISPOSITION"])

case("manual_conversion_detected", """
CREATE OR REPLACE PROCEDURE UP_MANUAL IS
BEGIN
  FOR r IN (SELECT data_string FROM my_raw_upload_table WHERE processed_flag = 'N') LOOP NULL; END LOOP;
END;
/
""", "ALREADY_MIGRATED_MANUAL")

case("mixed_manual_and_utl_file", base(10).replace("INSERT INTO t VALUES (l);",
                                                   "UPDATE my_raw_upload_table SET processed_flag = 'Y';"),
     "REVIEW_REQUIRED", blocker="MIXED_CONVERSION")

case("package_body_reader_needs_spec", """
CREATE OR REPLACE PACKAGE BODY PKG_UP IS
  PROCEDURE load(PO_STATUS_CODE OUT NUMBER) IS
    f UTL_FILE.FILE_TYPE; l VARCHAR2(4000);
  BEGIN
    MY_DIR_LIST_PROC('/in');
    f := UTL_FILE.FOPEN('INBOX', 'x.csv', 'r');
    UTL_FILE.GET_LINE(f, l);
    UTL_FILE.FCLOSE(f);
  END load;
END PKG_UP;
/
""", "REVIEW_REQUIRED", blocker="SESSION_PARAM_PACKAGE")

case("package_body_reader", """
CREATE OR REPLACE PACKAGE BODY PKG_UP IS
  PROCEDURE load(PO_STATUS_CODE OUT NUMBER, PI_SESSION_ID IN NUMBER) IS
    f UTL_FILE.FILE_TYPE; l VARCHAR2(4000);
  BEGIN
    MY_DIR_LIST_PROC('/in');
    f := UTL_FILE.FOPEN('INBOX', 'x.csv', 'r');
    UTL_FILE.GET_LINE(f, l);
    UTL_FILE.FCLOSE(f);
    UTL_FILE.FREMOVE('INBOX', 'x.csv');
  END load;
END PKG_UP;
/
""", "CONVERTED", contains=["p_unit_name  => 'PKG_UP.LOAD'", "p_session_id => PI_SESSION_ID"])

# --- session parameter and USERENV -----------------------------------------------
case("session_param_and_userenv", """
CREATE OR REPLACE PROCEDURE UP_SESS(PI_BUS_DATE IN VARCHAR2,
                                    PO_ERR_CODE OUT NUMBER) IS
  v_session_id NUMBER(8);
  v_other      VARCHAR2(100);
  f UTL_FILE.FILE_TYPE; l VARCHAR2(4000);
BEGIN
  SELECT USERENV('SESSIONID') INTO v_session_id FROM DUAL;
  v_other := SYS_CONTEXT('USERENV', 'SESSIONID');
  MY_DIR_LIST_PROC('/in');
  f := UTL_FILE.FOPEN('INBOX', 'x.csv', 'r');
  UTL_FILE.GET_LINE(f, l);
  UTL_FILE.FCLOSE(f);
END;
/
""", "CONVERTED_WITH_WARNINGS",
     contains=["PO_ERR_CODE OUT NUMBER,\n                                    pi_session_id IN NUMBER DEFAULT NULL /* ORAAS Migration */) IS",
               "-- SELECT USERENV('SESSIONID') INTO v_session_id FROM DUAL;  --ORAAS Migration\n  v_session_id := pi_session_id;",
               "v_other := pi_session_id;", "p_session_id    => pi_session_id"],
     warns=["SESSION_VAR_SIZE", "USERENV_SESSION_REPLACED"])

case("no_param_list", """
CREATE OR REPLACE PROCEDURE UP_NOPARAM IS
  f UTL_FILE.FILE_TYPE; l VARCHAR2(4000);
BEGIN
  MY_DIR_LIST_PROC('/in');
  f := UTL_FILE.FOPEN('INBOX', 'x.csv', 'r');
  UTL_FILE.GET_LINE(f, l);
  UTL_FILE.FCLOSE(f);
END;
/
""", "CONVERTED_WITH_WARNINGS", contains=["PROCEDURE UP_NOPARAM (pi_session_id IN NUMBER DEFAULT NULL) IS"])

case("existing_session_param_reused", base(11).replace("PO_ERR_CODE OUT NUMBER)", "PO_ERR_CODE OUT NUMBER, Pi_Session_Id IN VARCHAR2)"),
     "CONVERTED", contains=["p_session => Pi_Session_Id"], absent=["pi_session_id IN NUMBER DEFAULT NULL"])

# --- mark_input after FCLOSE ----------------------------------------------------
case("mark_input_flags", """
CREATE OR REPLACE PROCEDURE UP_MARK(PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE; o UTL_FILE.FILE_TYPE; l VARCHAR2(4000); v_feed_failed VARCHAR2(1) := 'N';
  i_file VARCHAR2(100) := 'x.csv';
BEGIN
  MY_DIR_LIST_PROC('/in');
  f := UTL_FILE.FOPEN('INBOX', i_file, 'R');
  o := UTL_FILE.FOPEN('OUT', 'y.rej', 'W');
  BEGIN
    LOOP UTL_FILE.GET_LINE(f, l); END LOOP;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN UTL_FILE.FCLOSE(f);
    WHEN UTL_FILE.READ_ERROR THEN
      UTL_FILE.FCLOSE(f);
      v_feed_failed := 'Y';
  END;
  UTL_FILE.FCLOSE(o);
  IF UTL_FILE.IS_OPEN(f) THEN UTL_FILE.FCLOSE(f); END IF;
END;
/
""", "CONVERTED_WITH_WARNINGS",
     contains=["WHEN NO_DATA_FOUND THEN ORAAS_UTL.FCLOSE(f);\n    oraas_utl.mark_input(p_filename => i_file, p_session => pi_session_id, "
               "p_flag => CASE WHEN (PO_ERR_CODE IS NULL OR PO_ERR_CODE = 0) AND NVL(v_feed_failed, 'N') <> 'Y' THEN 'Y' ELSE 'N' END, p_how => 'UP_MARK');",
               "ORAAS_UTL.FCLOSE(f);\n      oraas_utl.mark_input(p_filename => i_file, p_session => pi_session_id, p_flag => 'N', p_how => 'UP_MARK');",
               "THEN ORAAS_UTL.FCLOSE(f); oraas_utl.mark_input(", "/* ORAAS Migration */ END IF;"],
     count={"oraas_utl.mark_input(": 3})

case("mark_input_filename_not_visible", """
CREATE OR REPLACE PROCEDURE UP_VIS(PO_ERR_CODE OUT NUMBER) IS
  f UTL_FILE.FILE_TYPE; l VARCHAR2(4000);
  PROCEDURE open_it(p_name VARCHAR2) IS
  BEGIN
    f := UTL_FILE.FOPEN('INBOX', p_name, 'r');
  END;
BEGIN
  MY_DIR_LIST_PROC('/in');
  open_it('x.csv');
  UTL_FILE.GET_LINE(f, l);
  UTL_FILE.FCLOSE(f);
END;
/
""", "CONVERTED_WITH_WARNINGS", warns=["MARK_INPUT_SKIPPED"], count={"oraas_utl.mark_input(": 0})


def run(emit=None):
    failures = 0
    for c in CASES:
        errs = []
        try:
            out, rep = CONV.convert(c["src"])
            status, blk = rep["status"], None
            warns = {f.code for f in rep["findings"] if f.level == "WARN"}
        except C.ReviewRequired as e:
            out, blk, warns = None, e.code, set()
            status = "UPLOAD_SCOPE" if e.code == "UPLOAD_SCOPE" else "REVIEW_REQUIRED"
        if status != c["status"]:
            errs.append(f"status {status} != {c['status']}" + (f" ({blk})" if blk else ""))
        if c["blocker"] and blk != c["blocker"]:
            errs.append(f"blocker {blk} != {c['blocker']}")
        for s in c["contains"]:
            hay = out or ""
            if s not in hay and s not in hay.replace("\r\n", "\n"):
                errs.append(f"missing: {s!r}")
        for s in c["absent"]:
            if s in (out or ""):
                errs.append(f"unexpected: {s!r}")
        for s, n in c["count"].items():
            k = (out or "").count(s)
            if k != n:
                errs.append(f"count {s!r} = {k}, expected {n}")
        for w in c["warns"]:
            if w not in warns:
                errs.append(f"warning {w} not raised (got {sorted(warns)})")
        for w in c["nowarns"]:
            if w in warns:
                errs.append(f"warning {w} raised unexpectedly")
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
