-- =============================================================================
-- ORAAS_UTL unit tests (write/download side)
-- -----------------------------------------------------------------------------
-- RUN ONLY IN AN EMPTY SCRATCH SCHEMA (e.g. an Always Free Autonomous Database).
-- Installs the shim objects with a TEST adapter (tests/test_adapter.pkb) whose
-- ON_FILE_READY fails for file names starting with FAIL. Re-runnable.
--
--   sql user/pwd@db @oraas_utl_unit_tests.sql          (SQLcl or SQL*Plus, from tests/)
--
-- Expected result: every line printed starts with PASS, last line "FAILED=0".
-- Then run oraas_utl_upload_tests.sql in the same schema for the read side.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

WHENEVER SQLERROR CONTINUE
DROP TABLE oraas_file_out PURGE;
DROP TABLE oraas_file_in PURGE;
DROP TABLE oraas_file_log PURGE;
DROP SEQUENCE oraas_run_seq;
WHENEVER SQLERROR EXIT FAILURE

@@../plsql/01_oraas_file_tables.sql
@@../plsql/02_oraas_utl_adapter.pks
@@test_adapter.pkb
@@../plsql/03_oraas_utl.pks
@@../plsql/04_oraas_utl.pkb

-- Helper units for nested/stale frame tests -----------------------------------
CREATE OR REPLACE PROCEDURE oraas_t_inner IS
  fr PLS_INTEGER;
  f  oraas_utl.file_type;
BEGIN
  fr := oraas_utl.begin_unit('ORAAS_T_INNER');
  f := oraas_utl.fopen('DIR_T', 'inner.txt', 'w');
  oraas_utl.put_line(f, 'inner');
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, TRUE);
END;
/
CREATE OR REPLACE PROCEDURE oraas_t_outer IS
  fr PLS_INTEGER;
  f  oraas_utl.file_type;
BEGIN
  fr := oraas_utl.begin_unit('ORAAS_T_OUTER');
  f := oraas_utl.fopen('DIR_T', 'outer.txt', 'w');
  oraas_utl.put_line(f, 'outer-1');
  oraas_t_inner;                       -- nested converted unit
  oraas_utl.put_line(f, 'outer-2');
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, TRUE);
END;
/
CREATE OR REPLACE PROCEDURE oraas_t_leaky IS
  fr PLS_INTEGER;
  f  oraas_utl.file_type;
BEGIN
  fr := oraas_utl.begin_unit('ORAAS_T_LEAKY');
  f := oraas_utl.fopen('DIR_T', 'leaky.txt', 'w');
  oraas_utl.put_line(f, 'never submitted');
  oraas_utl.fclose(f);
  RAISE_APPLICATION_ERROR(-20999, 'leave without END_UNIT');
END;
/
CREATE OR REPLACE PROCEDURE oraas_t_clean IS
  fr PLS_INTEGER;
BEGIN
  fr := oraas_utl.begin_unit('ORAAS_T_CLEAN');
  oraas_utl.end_unit(fr, TRUE);
END;
/

DECLARE
  g_fail PLS_INTEGER := 0;
  g_pass PLS_INTEGER := 0;
  fr     PLS_INTEGER;
  f      oraas_utl.file_type;
  f2     oraas_utl.file_type;
  l_txt  NCLOB;
  l_cnt  NUMBER;
  l_s1   NUMBER;
  l_s2   NUMBER;
  l_ok   BOOLEAN;
  l_len  NUMBER;
  l_blk  BINARY_INTEGER;
  lf     CONSTANT VARCHAR2(1) := CHR(10);

  PROCEDURE check_(p_name VARCHAR2, p_cond BOOLEAN, p_info VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF NVL(p_cond, FALSE) THEN
      g_pass := g_pass + 1;
      DBMS_OUTPUT.PUT_LINE('PASS ' || p_name);
    ELSE
      g_fail := g_fail + 1;
      DBMS_OUTPUT.PUT_LINE('FAIL ' || p_name || CASE WHEN p_info IS NOT NULL THEN ' :: ' || p_info END);
    END IF;
  END check_;

  FUNCTION content(p_name VARCHAR2) RETURN NCLOB IS
    l NCLOB;
  BEGIN
    SELECT content INTO l FROM oraas_file_out WHERE file_name = p_name AND status <> 'FAILED';
    RETURN l;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END content;

  FUNCTION captured(p_name VARCHAR2) RETURN NUMBER IS
    n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO n FROM oraas_file_out WHERE file_name = p_name AND status <> 'FAILED';
    RETURN n;
  END captured;
BEGIN
  oraas_utl.reset_session;

  -- T01 byte layout of PUT/PUT_LINE/NEW_LINE/PUTF -----------------------------
  fr := oraas_utl.begin_unit('T01', p_business_date => '2026-10-01', p_context => 'JOB=7');
  f := oraas_utl.fopen('DIR_T', 't01.txt', 'W', 32767);
  oraas_utl.put_line(f, 'A');
  oraas_utl.put(f, 'B');
  oraas_utl.new_line(f, 2);
  oraas_utl.putf(f, '%s-%s|%s\n', 'x', 'y');
  oraas_utl.put_line(f, NULL);
  oraas_utl.fclose(f);
  check_('T01 handle nulled by FCLOSE', f.id IS NULL);
  oraas_utl.end_unit(fr, TRUE);
  l_txt := content('t01.txt');
  check_('T01 content bytes', TO_CHAR(l_txt) = 'A' || lf || 'B' || lf || lf || 'x-y|' || lf || lf,
         REPLACE(TO_CHAR(l_txt), lf, '\n'));
  SELECT COUNT(*) INTO l_cnt FROM oraas_file_out
   WHERE file_name = 't01.txt' AND unit_name = 'T01' AND interface_code = 'T01'
     AND context = 'JOB=7' AND business_date = '2026-10-01' AND location = 'DIR_T'
     AND is_empty = 'N' AND status = 'READY' AND byte_count = 9;
  check_('T01 metadata stored in ORAAS_FILE_OUT', l_cnt = 1);

  -- T02 success gate: failure status discards everything -------------------------
  fr := oraas_utl.begin_unit('T02');
  f := oraas_utl.fopen('DIR_T', 't02.txt', 'w');
  oraas_utl.put_line(f, 'x');
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, FALSE);
  check_('T02 failure status -> no file', captured('t02.txt') = 0);

  -- T03 FREMOVE cancels a closed file and an open file ------------------------
  fr := oraas_utl.begin_unit('T03');
  f := oraas_utl.fopen('DIR_T', 't03a.txt', 'w');
  oraas_utl.fclose(f);
  oraas_utl.fremove('DIR_T', 't03a.txt');
  f2 := oraas_utl.fopen('DIR_T', 't03b.txt', 'w');
  oraas_utl.fremove('dir_t', 't03b.txt');
  check_('T03 IS_OPEN true after removing an open file', oraas_utl.is_open(f2));
  oraas_utl.put_line(f2, 'lost');
  oraas_utl.fclose(f2);
  oraas_utl.fremove('DIR_T', 'never_existed.txt');      -- ignored, logged
  oraas_utl.end_unit(fr, TRUE);
  check_('T03 removed files not submitted', captured('t03a.txt') + captured('t03b.txt') = 0);

  -- T04 open handle at END_UNIT -------------------------------------------------
  fr := oraas_utl.begin_unit('T04');
  f := oraas_utl.fopen('DIR_T', 't04a.txt', 'w');
  oraas_utl.put_line(f, 'open');
  oraas_utl.end_unit(fr, TRUE);                          -- default: discard
  check_('T04 open handle discarded by default', captured('t04a.txt') = 0);
  check_('T04 handle invalid after END_UNIT', NOT oraas_utl.is_open(f));
  fr := oraas_utl.begin_unit('T04');
  f := oraas_utl.fopen('DIR_T', 't04b.txt', 'w');
  oraas_utl.put_line(f, 'open');
  oraas_utl.end_unit(fr, TRUE, p_submit_open => TRUE);  -- unit without FCLOSE
  check_('T04 open handle submitted when p_submit_open', TO_CHAR(content('t04b.txt')) = 'open' || lf);

  -- T05 empty file -> NULL content, IS_EMPTY = Y ------------------------------
  fr := oraas_utl.begin_unit('T05');
  f := oraas_utl.fopen('DIR_T', 't05.txt', 'w');
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, TRUE);
  SELECT COUNT(*) INTO l_cnt FROM oraas_file_out
   WHERE file_name = 't05.txt' AND is_empty = 'Y' AND content IS NULL;
  check_('T05 empty file stored with IS_EMPTY = Y', l_cnt = 1);

  -- T06 nested units: inner submitted first, one session for the whole call ---
  oraas_t_outer;
  check_('T06 outer content', TO_CHAR(content('outer.txt')) = 'outer-1' || lf || 'outer-2' || lf);
  check_('T06 inner content', TO_CHAR(content('inner.txt')) = 'inner' || lf);
  SELECT MAX(DECODE(file_name, 'inner.txt', run_id)), MAX(DECODE(file_name, 'outer.txt', run_id))
    INTO l_s1, l_s2 FROM oraas_file_out WHERE file_name IN ('inner.txt', 'outer.txt');
  check_('T06 same run id for nested units', l_s1 = l_s2);
  check_('T06 stack empty afterwards', oraas_utl.state_summary LIKE 'frames=0%', oraas_utl.state_summary);

  -- T07 stale frame from a unit that left without END_UNIT ---------------------
  BEGIN
    oraas_t_leaky;
  EXCEPTION
    WHEN OTHERS THEN NULL;
  END;
  check_('T07 leaked frame present', oraas_utl.state_summary LIKE 'frames=1%', oraas_utl.state_summary);
  oraas_t_clean;                       -- same call depth -> purges the stale frame
  check_('T07 stale frame purged', oraas_utl.state_summary LIKE 'frames=0%', oraas_utl.state_summary);
  check_('T07 leaked file never submitted', captured('leaky.txt') = 0);

  -- T08 adapter failure raises -20901, marks the row FAILED, leaves a clean state -----------------
  fr := oraas_utl.begin_unit('T08');
  f := oraas_utl.fopen('DIR_T', 'FAIL_t08.txt', 'w');
  oraas_utl.fclose(f);
  f := oraas_utl.fopen('DIR_T', 't08_after.txt', 'w');
  oraas_utl.fclose(f);
  BEGIN
    oraas_utl.end_unit(fr, TRUE);
    check_('T08 adapter failure raised', FALSE);
  EXCEPTION
    WHEN oraas_utl.handoff_failed THEN
      check_('T08 adapter failure raised', TRUE);
  END;
  check_('T08 later files not submitted', captured('t08_after.txt') = 0);
  SELECT COUNT(*) INTO l_cnt FROM oraas_file_out WHERE file_name = 'FAIL_t08.txt' AND status = 'FAILED';
  check_('T08 failed file marked FAILED', l_cnt = 1);
  check_('T08 state clean', oraas_utl.state_summary LIKE 'frames=0%', oraas_utl.state_summary);
  oraas_utl.end_unit(fr, FALSE);       -- second call on an ended frame is a no-op
  check_('T08 second END_UNIT is a no-op', TRUE);

  -- T09 FRENAME / FCOPY with line range / FGETATTR ----------------------------
  fr := oraas_utl.begin_unit('T09');
  f := oraas_utl.fopen('DIR_T', 't09.tmp', 'w');
  oraas_utl.put_line(f, 'L1');
  oraas_utl.put_line(f, 'L2');
  oraas_utl.put_line(f, 'L3');
  oraas_utl.put(f, 'L4');
  oraas_utl.fclose(f);
  oraas_utl.frename('DIR_T', 't09.tmp', 'DIR_OUT', 't09.txt');
  oraas_utl.fcopy('DIR_OUT', 't09.txt', 'DIR_OUT', 't09_copy.txt', 2, 3);
  oraas_utl.fgetattr('DIR_OUT', 't09.txt', l_ok, l_len, l_blk);
  check_('T09 FGETATTR exists and byte length', l_ok AND l_len = 11, TO_CHAR(l_len));
  BEGIN
    oraas_utl.frename('DIR_OUT', 't09_copy.txt', 'DIR_OUT', 't09.txt', FALSE);
    check_('T09 FRENAME onto existing raises RENAME_FAILED', FALSE);
  EXCEPTION
    WHEN oraas_utl.rename_failed THEN
      check_('T09 FRENAME onto existing raises RENAME_FAILED', SQLCODE = -29292);
  END;
  oraas_utl.end_unit(fr, TRUE);
  check_('T09 renamed file submitted under new name',
         captured('t09.tmp') = 0 AND TO_CHAR(content('t09.txt')) = 'L1' || lf || 'L2' || lf || 'L3' || lf || 'L4');
  check_('T09 FCOPY lines 2..3', TO_CHAR(content('t09_copy.txt')) = 'L2' || lf || 'L3' || lf,
         REPLACE(TO_CHAR(content('t09_copy.txt')), lf, '\n'));

  -- T10 NCHAR and multibyte byte count ------------------------------------------
  fr := oraas_utl.begin_unit('T10');
  f := oraas_utl.fopen_nchar('DIR_T', 't10.txt', 'w');
  oraas_utl.put_line_nchar(f, UNISTR('Gr\00FC\00DFe \4F60\597D'));
  oraas_utl.put_line(f, 'café');
  check_('T10 FGETPOS = UTF-8 bytes', oraas_utl.fgetpos(f) = LENGTHB(TO_CHAR(UNISTR('Gr\00FC\00DFe \4F60\597D'))) + 1 + LENGTHB('café') + 1);
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, TRUE);
  l_txt := TO_NCLOB(UNISTR('Gr\00FC\00DFe \4F60\597D') || lf || 'café' || lf);
  check_('T10 NCHAR content preserved', DBMS_LOB.COMPARE(content('t10.txt'), l_txt) = 0);

  -- T11 UTL_FILE-compatible exception codes -----------------------------------
  fr := oraas_utl.begin_unit('T11');
  f := oraas_utl.fopen('DIR_T', 't11.txt', 'w');
  f2 := f;                            -- copy of the handle (as passed to a wrapper)
  oraas_utl.fclose(f);
  BEGIN
    oraas_utl.put_line(f2, 'after close');
    check_('T11 write after close raises INVALID_FILEHANDLE', FALSE);
  EXCEPTION
    WHEN oraas_utl.invalid_filehandle THEN
      check_('T11 write after close raises INVALID_FILEHANDLE', SQLCODE = -29282);
  END;
  BEGIN
    f := oraas_utl.fopen('DIR_T', 'in.txt', 'r');
    check_('T11 read mode raises INVALID_OPERATION', FALSE);
  EXCEPTION
    WHEN oraas_utl.invalid_operation THEN
      check_('T11 read mode raises INVALID_OPERATION', SQLCODE = -29283);
  END;
  BEGIN
    f := oraas_utl.fopen('DIR_T', 'x.txt', 'z');
    check_('T11 bad mode raises INVALID_MODE', FALSE);
  EXCEPTION
    WHEN oraas_utl.invalid_mode THEN
      check_('T11 bad mode raises INVALID_MODE', SQLCODE = -29281);
  END;
  oraas_utl.end_unit(fr, TRUE);

  -- T12 FCLOSE_ALL: IS_OPEN stays TRUE (UTL_FILE doc), file is kept -----------
  fr := oraas_utl.begin_unit('T12');
  f := oraas_utl.fopen('DIR_T', 't12.txt', 'w');
  oraas_utl.put(f, 'z');
  oraas_utl.fclose_all;
  check_('T12 IS_OPEN after FCLOSE_ALL', oraas_utl.is_open(f));
  oraas_utl.fclose(f);                -- allowed, no error
  oraas_utl.end_unit(fr, TRUE);
  check_('T12 file submitted', TO_CHAR(content('t12.txt')) = 'z');

  -- T13 'w' on a pending name supersedes it; 'a' appends ------------------------
  fr := oraas_utl.begin_unit('T13');
  f := oraas_utl.fopen('DIR_T', 't13.txt', 'w');
  oraas_utl.put_line(f, 'old');
  oraas_utl.fclose(f);
  f := oraas_utl.fopen('DIR_T', 't13.txt', 'w');
  oraas_utl.put_line(f, 'new');
  oraas_utl.fclose(f);
  f := oraas_utl.fopen('DIR_T', 't13.txt', 'a');
  oraas_utl.put_line(f, 'more');
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, TRUE);
  check_('T13 truncate then append', TO_CHAR(content('t13.txt')) = 'new' || lf || 'more' || lf
         AND captured('t13.txt') = 1);

  -- T14 volume: 200,000 lines, exact length ------------------------------------
  fr := oraas_utl.begin_unit('T14');
  f := oraas_utl.fopen('DIR_T', 't14.txt', 'w', 32767);
  FOR i IN 1 .. 200000 LOOP
    oraas_utl.put_line(f, RPAD('R' || i, 100, '~'));
  END LOOP;
  oraas_utl.fclose(f);
  oraas_utl.end_unit(fr, TRUE);
  SELECT DBMS_LOB.GETLENGTH(content) INTO l_len FROM oraas_file_out WHERE file_name = 't14.txt';
  check_('T14 200k lines length', l_len = 200000 * 101, TO_CHAR(l_len));

  -- T15 FOPEN outside a converted unit is refused -----------------------------
  BEGIN
    f := oraas_utl.fopen('DIR_T', 't15.txt', 'w');
    check_('T15 FOPEN without frame raises', FALSE);
  EXCEPTION
    WHEN oraas_utl.invalid_operation THEN
      check_('T15 FOPEN without frame raises', TRUE);
  END;

  DBMS_OUTPUT.PUT_LINE('PASSED=' || g_pass || ' FAILED=' || g_fail);
END;
/
