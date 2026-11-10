-- =============================================================================
-- ORAAS_UTL unit tests (read/upload side)
-- -----------------------------------------------------------------------------
-- RUN ONLY IN THE SCRATCH SCHEMA prepared by oraas_utl_unit_tests.sql (run that
-- first: it installs the tables, the test adapter and the package).
-- Expected result: every line starts with PASS, last line "FAILED=0".
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
WHENEVER SQLERROR EXIT FAILURE

DELETE FROM oraas_file_in;

-- Input lines as a loader would store them (CR stripped, no blank lines, LINE_NO from 1)
DECLARE
  PROCEDURE add(p_if VARCHAR2, p_file VARCHAR2, p_sess VARCHAR2, p_n PLS_INTEGER, p_text VARCHAR2,
                p_age NUMBER DEFAULT 0) IS
  BEGIN
    INSERT INTO oraas_file_in (line_no, line_text, load_id, loaded_at, file_name, interface_code, processed_flag)
    VALUES (p_n, p_text, p_sess, SYSDATE - p_age, p_file, p_if, 'N');
  END;
BEGIN
  add('UP_T_READER', 'a.csv', 'S1', 1, 'HDR~20261008');
  add('UP_T_READER', 'a.csv', 'S1', 2, 'row-1');
  add('UP_T_READER', 'a.csv', 'S1', 3, 'TRL~1');
  add('UP_T_READER', 'b.csv', 'S2', 1, 'only line');
  -- two loads of the same name: the oldest is served first
  add('UP_T_READER', 'dup.csv', 'OLD', 1, 'old load', 2);
  add('UP_T_READER', 'dup.csv', 'NEW', 1, 'new load', 0);
  -- other interface: never visible to UP_T_READER
  add('OTHER_UPLOAD', 'a.csv', 'S9', 1, 'not mine');
  -- big file: 2,500 lines (crosses the 1,000-line fetch chunks)
  FOR i IN 1 .. 2500 LOOP
    add('UP_T_READER', 'big.csv', 'S3', i, 'L' || i);
  END LOOP;
  -- long line for linesize tests
  add('UP_T_READER', 'long.csv', 'S4', 1, RPAD('x', 3000, 'x'));
  -- multibyte
  add('UP_T_READER', 'mb.csv', 'S5', 1, UNISTR('Gr\00FC\00DFe \4F60\597D'));
  COMMIT;
END;
/

-- A converted-style upload unit (what the converter produces from legacy code)
CREATE OR REPLACE PROCEDURE up_t_reader(p_test IN VARCHAR2, po_out OUT VARCHAR2,
                                        pi_session_id IN NUMBER DEFAULT NULL) IS
  l_oraas_frame PLS_INTEGER;
  f   oraas_utl.file_type;
  l   VARCHAR2(4000);
  s   VARCHAR2(4000);
  n   PLS_INTEGER := 0;
BEGIN
  l_oraas_frame := oraas_utl.begin_unit(p_unit_name => 'UP_T_READER', p_session_id => pi_session_id);
  IF p_test = 'LIST' THEN
    SELECT LISTAGG(file_name || ':' || file_size, ',') WITHIN GROUP (ORDER BY file_name) INTO po_out
      FROM TABLE(oraas_utl.list_input_files);
  ELSIF p_test = 'READ_A' THEN
    f := oraas_utl.fopen('INBOX', 'a.csv', 'R');
    LOOP
      BEGIN
        oraas_utl.get_line(f, l);
      EXCEPTION WHEN NO_DATA_FOUND THEN EXIT;
      END;
      s := s || l || '|';
    END LOOP;
    oraas_utl.fclose(f);
    po_out := s;
  ELSIF p_test = 'COUNT_BIG' THEN
    f := oraas_utl.fopen('INBOX', 'big.csv', 'r', 32767);
    BEGIN
      LOOP
        oraas_utl.get_line(f, l);
        n := n + 1;
        IF n = 2500 THEN s := l; END IF;
      END LOOP;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
    END;
    po_out := n || ':' || s;
  ELSIF p_test = 'DUP' THEN
    f := oraas_utl.fopen('INBOX', 'dup.csv', 'r');
    oraas_utl.get_line(f, l);
    po_out := l;
  ELSIF p_test = 'MISSING' THEN
    BEGIN
      f := oraas_utl.fopen('INBOX', 'nope.csv', 'r');
      po_out := 'opened';
    EXCEPTION WHEN oraas_utl.invalid_operation THEN po_out := 'INVALID_OPERATION ' || SQLCODE;
    END;
  ELSIF p_test = 'LINESIZE' THEN
    f := oraas_utl.fopen('INBOX', 'long.csv', 'r');           -- default max_linesize 1024
    BEGIN
      oraas_utl.get_line(f, l);
      po_out := 'read';
    EXCEPTION WHEN oraas_utl.read_error THEN po_out := 'READ_ERROR ' || SQLCODE;
    END;
  ELSIF p_test = 'SMALLBUF' THEN
    DECLARE
      small VARCHAR2(10);
    BEGIN
      f := oraas_utl.fopen('INBOX', 'long.csv', 'r', 32767);
      oraas_utl.get_line(f, small);
      po_out := 'read';
    EXCEPTION WHEN VALUE_ERROR THEN po_out := 'VALUE_ERROR';
    END;
  ELSIF p_test = 'MB' THEN
    f := oraas_utl.fopen('INBOX', 'mb.csv', 'r');
    oraas_utl.get_line(f, l);
    po_out := CASE WHEN l = TO_CHAR(UNISTR('Gr\00FC\00DFe \4F60\597D')) THEN 'SAME' ELSE 'DIFF' END;
  ELSIF p_test = 'WRITE_HANDLE_READ' THEN
    BEGIN
      f := oraas_utl.fopen('OUT', 'w.txt', 'w');
      oraas_utl.get_line(f, l);
    EXCEPTION WHEN oraas_utl.invalid_operation THEN po_out := 'INVALID_OPERATION';
    END;
  ELSIF p_test = 'MOVE_OK' THEN
    oraas_utl.frename('INBOX', 'a.csv', 'UPT_OK', 'a.csv', TRUE);
    ROLLBACK;                                            -- the move must survive, as legacy
  ELSIF p_test = 'MOVE_ERR' THEN
    oraas_utl.fcopy('INBOX', 'b.csv', 'UPT_ERR', 'b.csv');
    oraas_utl.fremove('INBOX', 'b.csv');
  ELSIF p_test = 'MARK_THEN_ERR' THEN
    f := oraas_utl.fopen('INBOX', 'mb.csv', 'r');
    oraas_utl.fclose(f);
    oraas_utl.mark_input(p_filename => 'mb.csv', p_session => NULL, p_flag => 'Y', p_how => 'UP_T_READER');
    po_out := 'marked';
    oraas_utl.frename('INBOX', 'mb.csv', 'UPT_ERR', 'mb.csv');    -- later error move wins
  ELSIF p_test = 'REOPEN' THEN
    f := oraas_utl.fopen('INBOX', 'big.csv', 'r');
    oraas_utl.fclose(f);
    oraas_utl.mark_input(p_filename => 'big.csv', p_session => pi_session_id, p_flag => 'N', p_how => 'UP_T_READER');
    oraas_utl.mark_input(p_filename => 'big.csv', p_session => pi_session_id, p_flag => 'Y', p_how => 'UP_T_READER');
    f := oraas_utl.fopen('INBOX', 'big.csv', 'r');               -- re-open after marking (two-pass units)
    oraas_utl.get_line(f, l);
    po_out := l;
  ELSIF p_test = 'BADFLAG' THEN
    BEGIN
      oraas_utl.mark_input(p_filename => 'big.csv', p_flag => 'X');
      po_out := 'accepted';
    EXCEPTION WHEN oraas_utl.invalid_operation THEN po_out := 'INVALID_OPERATION';
    END;
  ELSIF p_test = 'ISOPEN' THEN
    f := oraas_utl.fopen('INBOX', 'big.csv', 'r');
    po_out := CASE WHEN oraas_utl.is_open(f) THEN 'Y' ELSE 'N' END;
    oraas_utl.fclose_all;
    po_out := po_out || CASE WHEN oraas_utl.is_open(f) THEN 'Y' ELSE 'N' END;   -- UTL_FILE doc: still TRUE
    oraas_utl.fclose(f);                                                          -- no error
    po_out := po_out || CASE WHEN oraas_utl.is_open(f) THEN 'Y' ELSE 'N' END;
  END IF;
  oraas_utl.end_unit(l_oraas_frame, TRUE);
EXCEPTION
  WHEN OTHERS THEN
    oraas_utl.end_unit(l_oraas_frame, FALSE);
    RAISE;
END;
/

DECLARE
  g_fail PLS_INTEGER := 0;
  g_pass PLS_INTEGER := 0;
  v      VARCHAR2(32767);
  n      NUMBER;
  PROCEDURE check_(p_name VARCHAR2, p_cond BOOLEAN, p_info VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF NVL(p_cond, FALSE) THEN
      g_pass := g_pass + 1; DBMS_OUTPUT.PUT_LINE('PASS ' || p_name);
    ELSE
      g_fail := g_fail + 1; DBMS_OUTPUT.PUT_LINE('FAIL ' || p_name || ' :: ' || p_info);
    END IF;
  END;
  FUNCTION flag(p_file VARCHAR2, p_sess VARCHAR2) RETURN VARCHAR2 IS
    f VARCHAR2(10);
  BEGIN
    SELECT MAX(processed_flag) || COUNT(DISTINCT processed_flag) INTO f FROM oraas_file_in
     WHERE interface_code = 'UP_T_READER' AND file_name = p_file AND load_id = p_sess;
    RETURN f;
  END;
BEGIN
  oraas_utl.reset_session;

  up_t_reader('LIST', v);
  check_('U01 listing shows only this interface, unprocessed files',
         v LIKE 'a.csv:%' AND INSTR(v, 'big.csv') > 0 AND INSTR(v, 'dup.csv') > 0 AND INSTR(v, 'not mine') = 0, v);
  check_('U01 file size = bytes + 1 per line', INSTR(v, 'a.csv:' || (LENGTHB('HDR~20261008') + LENGTHB('row-1') + LENGTHB('TRL~1') + 3)) > 0, v);

  up_t_reader('READ_A', v);
  check_('U02 lines in LINE_NO order, NO_DATA_FOUND at end', v = 'HDR~20261008|row-1|TRL~1|', v);

  up_t_reader('COUNT_BIG', v);
  check_('U03 2,500 lines across fetch chunks', v = '2500:L2500', v);

  up_t_reader('DUP', v);
  check_('U04 oldest load of a duplicate name served first', v = 'old load', v);

  up_t_reader('MISSING', v);
  check_('U05 missing file raises INVALID_OPERATION (-29283)', v = 'INVALID_OPERATION -29283', v);

  up_t_reader('LINESIZE', v);
  check_('U06 line longer than max_linesize raises READ_ERROR (-29284)', v = 'READ_ERROR -29284', v);

  up_t_reader('SMALLBUF', v);
  check_('U07 line longer than the buffer raises VALUE_ERROR', v = 'VALUE_ERROR', v);

  up_t_reader('MB', v);
  check_('U08 multibyte line unchanged', v = 'SAME', v);

  up_t_reader('WRITE_HANDLE_READ', v);
  check_('U09 GET_LINE on a write handle raises INVALID_OPERATION', v = 'INVALID_OPERATION', v);

  up_t_reader('ISOPEN', v);
  check_('U10 IS_OPEN / FCLOSE_ALL / FCLOSE on a read handle', v = 'YYN', v);

  up_t_reader('MOVE_OK', v);
  check_('U11 FRENAME to a success folder marks Y and survives ROLLBACK', flag('a.csv', 'S1') = 'Y1', flag('a.csv', 'S1'));

  up_t_reader('MOVE_ERR', v);
  check_('U12 FCOPY to error folder + FREMOVE marks E', flag('b.csv', 'S2') = 'E1', flag('b.csv', 'S2'));

  SELECT COUNT(*) INTO n FROM oraas_file_in WHERE interface_code = 'OTHER_UPLOAD' AND processed_flag = 'N';
  check_('U13 other interface untouched', n = 1);

  up_t_reader('LIST', v);
  check_('U14 processed files no longer listed', INSTR(v, 'a.csv') = 0 AND INSTR(v, 'b.csv') = 0, v);

  BEGIN
    SELECT COUNT(*) INTO n FROM TABLE(oraas_utl.list_input_files);
    check_('U15 listing outside a converted unit raises', FALSE);
  EXCEPTION WHEN oraas_utl.invalid_operation THEN
    check_('U15 listing outside a converted unit raises', TRUE);
  END;

  up_t_reader('DUP', v, pi_session_id => NULL);
  up_t_reader('LIST', v);
  -- load id passed by the caller: only that load is listed and read
  DELETE FROM oraas_file_in WHERE load_id = 'OLD';
  INSERT INTO oraas_file_in (line_no, line_text, load_id, loaded_at, file_name, interface_code, processed_flag)
  VALUES (1, 'sess 77', '77', SYSDATE, 'dup.csv', 'UP_T_READER', 'N');
  COMMIT;
  up_t_reader('DUP', v, pi_session_id => 77);
  check_('U17 given load id selects that load', v = 'sess 77', v);
  up_t_reader('LIST', v, pi_session_id => 77);
  check_('U18 listing restricted to the given load id', v LIKE 'dup.csv:%' AND INSTR(v, ',') = 0, v);

  up_t_reader('MARK_THEN_ERR', v);
  check_('U19 MARK_INPUT Y then move to error folder ends as E', flag('mb.csv', 'S5') = 'E1', flag('mb.csv', 'S5'));

  up_t_reader('REOPEN', v);
  check_('U20 re-open after MARK_INPUT reads the same load', v = 'L1' AND flag('big.csv', 'S3') = 'Y1', v || ' ' || flag('big.csv', 'S3'));

  up_t_reader('BADFLAG', v);
  check_('U21 invalid flag raises INVALID_OPERATION', v = 'INVALID_OPERATION', v);

  check_('U16 no frames left', oraas_utl.state_summary LIKE 'frames=0%', oraas_utl.state_summary);
  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('PASSED=' || g_pass || ' FAILED=' || g_fail);
END;
/
