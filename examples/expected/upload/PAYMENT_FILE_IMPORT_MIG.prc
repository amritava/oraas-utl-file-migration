-- ORAAS_UTL_UPLOAD_GENERATED v1.0.0: UTL_FILE -> ORAAS_UTL; 1 frame(s). Compile and byte-compare before release.
CREATE OR REPLACE PROCEDURE payment_file_import (
    pi_bus_date     IN  VARCHAR2,   -- DD/MM/YYYY
    pi_store_no    IN  NUMBER,
    po_status_code  OUT NUMBER,
    po_status_desc  OUT VARCHAR2,
    pi_session_id IN NUMBER DEFAULT NULL /* ORAAS Migration */) IS
      l_oraas_frame PLS_INTEGER;  -- ORAAS: file frame (generated)
/* -----------------------------------------------------------------------------
   INVENTED EXAMPLE (legacy, before migration). Lists the inbox with a
   site-specific listing procedure, reads each CSV file line by line in a
   nested routine with UTL_FILE-specific handlers, rejects blank lines, moves
   each file to a done or error folder with FRENAME, and tags staging rows with
   the database session id.
   ----------------------------------------------------------------------------- */
  ls_inbox     VARCHAR2(200) := 'PAY_INBOX';
  ls_done      VARCHAR2(200) := 'PAY_DONE';
  ls_error     VARCHAR2(200) := 'PAY_ERROR';
  lv_file      VARCHAR2(200);
  v_session_id NUMBER(8);

  CURSOR c_files IS
    SELECT file_name, file_size FROM my_dir_list_table ORDER BY file_name;

  PROCEDURE archive_file (p_file VARCHAR2, p_ok BOOLEAN) IS
  BEGIN
    ORAAS_UTL.FCLOSE_ALL;
    IF p_ok THEN
      ORAAS_UTL.FRENAME(src_location => ls_inbox, src_filename => p_file,
                       dest_location => ls_done, dest_filename => p_file, overwrite => TRUE);
    ELSE
      ORAAS_UTL.FRENAME(src_location => ls_inbox, src_filename => p_file,
                       dest_location => ls_error, dest_filename => p_file, overwrite => TRUE);
    END IF;
  EXCEPTION
    WHEN ORAAS_UTL.RENAME_FAILED THEN
      po_status_code := -1;
      po_status_desc := 'Move failed for ' || p_file;
  END archive_file;

  PROCEDURE load_file (p_dir VARCHAR2, p_file VARCHAR2, p_error OUT VARCHAR2) IS
    fh      ORAAS_UTL.FILE_TYPE;
    l_line  VARCHAR2(32767);
  BEGIN
    BEGIN
      fh := ORAAS_UTL.FOPEN(p_dir, p_file, 'R');
    EXCEPTION
      WHEN ORAAS_UTL.INVALID_OPERATION THEN
        p_error := 'Cannot open ' || p_file;
        RETURN;
    END;
    LOOP
      BEGIN
        ORAAS_UTL.GET_LINE(fh, l_line);
        IF TRIM(l_line) IS NULL THEN
          p_error := 'Blank line in ' || p_file;
          ORAAS_UTL.FCLOSE(fh);
          oraas_utl.mark_input(p_filename => p_file, p_session => pi_session_id, p_flag => CASE WHEN (po_status_code IS NULL OR po_status_code = 0) THEN 'Y' ELSE 'N' END, p_how => 'PAYMENT_FILE_IMPORT');  --ORAAS Migration
          RETURN;
        END IF;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          ORAAS_UTL.FCLOSE(fh);
          oraas_utl.mark_input(p_filename => p_file, p_session => pi_session_id, p_flag => CASE WHEN (po_status_code IS NULL OR po_status_code = 0) THEN 'Y' ELSE 'N' END, p_how => 'PAYMENT_FILE_IMPORT');  --ORAAS Migration
          EXIT;
        WHEN ORAAS_UTL.READ_ERROR THEN
          ROLLBACK;
          p_error := 'Read error in ' || p_file;
          ORAAS_UTL.FCLOSE(fh);
          oraas_utl.mark_input(p_filename => p_file, p_session => pi_session_id, p_flag => 'N', p_how => 'PAYMENT_FILE_IMPORT');  --ORAAS Migration
          RETURN;
        WHEN VALUE_ERROR THEN
          ROLLBACK;
          p_error := 'Line too long in ' || p_file;
          ORAAS_UTL.FCLOSE(fh);
          oraas_utl.mark_input(p_filename => p_file, p_session => pi_session_id, p_flag => 'N', p_how => 'PAYMENT_FILE_IMPORT');  --ORAAS Migration
          RETURN;
      END;
      INSERT INTO payment_staging (session_id, file_name, raw_line, account_no, amount)
      VALUES (v_session_id, p_file, l_line,
              REPLACE(TRIM(REGEXP_SUBSTR(l_line, '[^,]+', 1, 1)), CHR(13)),
              TO_NUMBER(REPLACE(TRIM(REGEXP_SUBSTR(l_line, '[^,]+', 1, 2)), CHR(13))));
    END LOOP;
  END load_file;

BEGIN
  l_oraas_frame := oraas_utl.begin_unit(
      p_unit_name     => 'PAYMENT_FILE_IMPORT',
      p_session_id    => pi_session_id,
      p_business_date => pi_bus_date);  -- ORAAS (generated)
  po_status_code := 0;
  BEGIN
    -- SELECT USERENV('SESSIONID') INTO v_session_id FROM DUAL;  --ORAAS Migration
    v_session_id := pi_session_id;  --ORAAS Migration
  EXCEPTION
    WHEN OTHERS THEN
      po_status_code := -1;
      po_status_desc := 'No session id';
      oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
      RETURN;
  END;

  DELETE FROM my_dir_list_table;
  my_dir_list_proc(ls_inbox);

  FOR f IN c_files LOOP
    lv_file := f.file_name;
    IF f.file_size > 0 THEN
      load_file(ls_inbox, lv_file, po_status_desc);
      IF po_status_desc IS NOT NULL THEN
        archive_file(lv_file, FALSE);
        po_status_code := -1;
        oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
        RETURN;
      END IF;
      archive_file(lv_file, TRUE);
    END IF;
  END LOOP;

  INSERT INTO payments (account_no, amount, bus_date, store_no)
  SELECT account_no, amount, TO_DATE(pi_bus_date, 'DD/MM/YYYY'), pi_store_no
    FROM payment_staging
   WHERE session_id = v_session_id;
  DELETE FROM payment_staging WHERE session_id = v_session_id;
  COMMIT;
  oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
EXCEPTION
  WHEN OTHERS THEN
    po_status_code := -1;
    po_status_desc := 'payment_file_import: ' || SQLERRM;
    oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
END payment_file_import;
/
