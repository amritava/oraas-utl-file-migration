-- ORAAS_UTL_UPLOAD_GENERATED v1.0.0: UTL_FILE -> ORAAS_UTL; 1 frame(s). Compile and byte-compare before release.
CREATE OR REPLACE PROCEDURE customer_feed_load (
    pi_bus_date    IN  VARCHAR2,
    po_error_code  OUT VARCHAR2,
    po_error_desc  OUT VARCHAR2,
    pi_session_id IN NUMBER DEFAULT NULL /* ORAAS Migration */) AS
      l_oraas_frame PLS_INTEGER;  -- ORAAS: file frame (generated)
/* -----------------------------------------------------------------------------
   INVENTED EXAMPLE (legacy). Fixed-width feed with header and trailer: first
   pass checks the trailer count, second pass (file opened again) loads the
   details. Text status code, error-flag variable, GOTO exit labels, archive
   by FCOPY + FREMOVE.
   ----------------------------------------------------------------------------- */
  v_feed_failed   VARCHAR2(1) := 'N';
  ls_inbox        VARCHAR2(100) := 'CUST_IN';
  ls_archive           VARCHAR2(100) := 'CUST_ARCHIVE';
  ls_rejected          VARCHAR2(100) := 'CUST_REJECTED';
  lv_feed_file     VARCHAR2(200);
  v_hdr_seen      VARCHAR2(1);
  v_trl_count     NUMBER;
  v_lines         NUMBER;

  CURSOR c_files IS SELECT file_name, file_size FROM my_dir_list_table;

  PROCEDURE read_feed IS
    infile  ORAAS_UTL.FILE_TYPE;
    buf     VARCHAR2(2000);
  BEGIN
    infile := ORAAS_UTL.FOPEN(ls_inbox, lv_feed_file, 'R');
    v_feed_failed := 'Y';
    v_hdr_seen := 'N';
    v_lines := 0;
    LOOP
      BEGIN
        ORAAS_UTL.GET_LINE(infile, buf);
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          GOTO finish;
      END;
      v_lines := v_lines + 1;
      IF SUBSTR(buf, 1, 3) = 'HDR' THEN
        v_hdr_seen := 'Y';
      ELSIF SUBSTR(buf, 1, 3) = 'TRL' THEN
        v_trl_count := TO_NUMBER(TRIM(SUBSTR(buf, 4, 10)));
        ORAAS_UTL.FCLOSE(infile);
        oraas_utl.mark_input(p_filename => lv_feed_file, p_session => pi_session_id, p_flag => CASE WHEN (TRIM(po_error_code) IS NULL OR TRIM(po_error_code) = '0') AND NVL(v_feed_failed, 'N') <> 'Y' THEN 'Y' ELSE 'N' END, p_how => 'CUSTOMER_FEED_LOAD');  --ORAAS Migration
        EXIT;
      END IF;
    END LOOP;
    IF v_hdr_seen = 'Y' AND v_trl_count = v_lines THEN
      v_feed_failed := 'N';
    END IF;
    IF v_feed_failed = 'Y' THEN
      GOTO finish;
    END IF;

    infile := ORAAS_UTL.FOPEN(ls_inbox, lv_feed_file, 'R');
    LOOP
      BEGIN
        ORAAS_UTL.GET_LINE(infile, buf);
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          GOTO finish;
      END;
      IF SUBSTR(buf, 1, 3) NOT IN ('HDR', 'TRL') THEN
        INSERT INTO customers_stage (customer_no, customer_name, segment)
        VALUES (TRIM(SUBSTR(buf, 1, 10)), TRIM(SUBSTR(buf, 11, 40)), TRIM(SUBSTR(buf, 51, 2)));
      END IF;
    END LOOP;
    <<finish>>
    IF ORAAS_UTL.IS_OPEN(infile) THEN
      ORAAS_UTL.FCLOSE(infile);
      oraas_utl.mark_input(p_filename => lv_feed_file, p_session => pi_session_id, p_flag => CASE WHEN (TRIM(po_error_code) IS NULL OR TRIM(po_error_code) = '0') AND NVL(v_feed_failed, 'N') <> 'Y' THEN 'Y' ELSE 'N' END, p_how => 'CUSTOMER_FEED_LOAD');  --ORAAS Migration
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      IF ORAAS_UTL.IS_OPEN(infile) THEN
        ORAAS_UTL.FCLOSE(infile);
        oraas_utl.mark_input(p_filename => lv_feed_file, p_session => pi_session_id, p_flag => 'N', p_how => 'CUSTOMER_FEED_LOAD');  --ORAAS Migration
      END IF;
      v_feed_failed := 'Y';
  END read_feed;

BEGIN
  l_oraas_frame := oraas_utl.begin_unit(
      p_unit_name     => 'CUSTOMER_FEED_LOAD',
      p_session_id    => pi_session_id,
      p_business_date => pi_bus_date);  -- ORAAS (generated)
  po_error_code := '0';
  DELETE FROM my_dir_list_table;
  my_dir_list_proc('/feeds/customer');
  FOR f IN c_files LOOP
    lv_feed_file := TRIM(f.file_name);
    v_feed_failed := 'N';
    IF f.file_size > 0 THEN
      read_feed;
    ELSE
      v_feed_failed := 'Y';
    END IF;
    IF v_feed_failed = 'Y' THEN
      ROLLBACK;
      ORAAS_UTL.FCOPY(ls_inbox, lv_feed_file, ls_rejected, lv_feed_file);
      ORAAS_UTL.FREMOVE(ls_inbox, lv_feed_file);
    ELSE
      COMMIT;
      ORAAS_UTL.FCOPY(ls_inbox, lv_feed_file, ls_archive, lv_feed_file);
      ORAAS_UTL.FREMOVE(ls_inbox, lv_feed_file);
    END IF;
  END LOOP;
  <<all_done>>
  NULL;
  oraas_utl.end_unit(l_oraas_frame, (TRIM(po_error_code) IS NULL OR TRIM(po_error_code) = '0'));
EXCEPTION
  WHEN OTHERS THEN
    po_error_code := '-1';
    po_error_desc := 'customer_feed_load: ' || SQLERRM;
    oraas_utl.end_unit(l_oraas_frame, (TRIM(po_error_code) IS NULL OR TRIM(po_error_code) = '0'));
END customer_feed_load;
/
