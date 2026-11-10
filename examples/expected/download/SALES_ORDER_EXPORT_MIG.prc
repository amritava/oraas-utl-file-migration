-- ORAAS_UTL_DOWNLOAD_GENERATED v1.0.0: UTL_FILE -> ORAAS_UTL; 1 frame(s). Compile and byte-compare before release.
CREATE OR REPLACE PROCEDURE sales_order_export (
    pi_out_dir      IN  VARCHAR2,
    pi_archive_dir  IN  VARCHAR2,
    pi_bus_date     IN  DATE,
    pi_region       IN  VARCHAR2,
    po_status_code  OUT NUMBER,
    po_status_desc  OUT VARCHAR2) IS
      l_oraas_frame PLS_INTEGER;  -- ORAAS: file frame (generated)
/* -----------------------------------------------------------------------------
   INVENTED EXAMPLE (legacy, before migration). Writes a header/detail/trailer
   order file plus an archive copy through a wrapper; removes both files when
   no line was written; UTL_FILE-specific handlers; exit label with GOTO.
   ----------------------------------------------------------------------------- */
  lv_file_name   VARCHAR2(200);
  lv_line        VARCHAR2(4000);
  lv_error       VARCHAR2(4000);
  ln_lines       NUMBER := 0;
  lf_main        ORAAS_UTL.FILE_TYPE;
  lf_archive     ORAAS_UTL.FILE_TYPE;

  CURSOR c_orders IS
    SELECT order_no || '|' || customer_no || '|' || TO_CHAR(amount, 'FM9999999990.00') AS rec
      FROM sales_orders
     WHERE order_date = pi_bus_date
       AND region     = pi_region
     ORDER BY order_no;

  PROCEDURE write_rec (p_handle ORAAS_UTL.FILE_TYPE, p_text VARCHAR2, p_error OUT VARCHAR2) IS
  BEGIN
    p_error := NULL;
    ORAAS_UTL.PUT_LINE(p_handle, p_text);
    ORAAS_UTL.FFLUSH(p_handle);
  EXCEPTION
    WHEN ORAAS_UTL.INVALID_FILEHANDLE THEN
      p_error := 'Invalid file handle';
    WHEN ORAAS_UTL.WRITE_ERROR THEN
      p_error := 'Write error';
    WHEN OTHERS THEN
      p_error := SQLERRM;
  END write_rec;

BEGIN
  l_oraas_frame := oraas_utl.begin_unit(
      p_unit_name     => 'SALES_ORDER_EXPORT',
      p_business_date => TO_CHAR(pi_bus_date, 'YYYY-MM-DD'));  -- ORAAS (generated)
  po_status_code := 0;
  lv_file_name := 'orders_' || LOWER(pi_region) || '_' || TO_CHAR(pi_bus_date, 'YYYYMMDD') || '.txt';

  BEGIN
    lf_main    := ORAAS_UTL.FOPEN(pi_out_dir, lv_file_name, 'w', 32767);
    lf_archive := ORAAS_UTL.FOPEN(pi_archive_dir, lv_file_name, 'w', 32767);
  EXCEPTION
    WHEN ORAAS_UTL.INVALID_PATH THEN
      po_status_code := -1;
      po_status_desc := 'Invalid directory for ' || lv_file_name;
      GOTO finish;
    WHEN OTHERS THEN
      po_status_code := -1;
      po_status_desc := 'Cannot open ' || lv_file_name || ': ' || SQLERRM;
      GOTO finish;
  END;

  write_rec(lf_main, 'HDR|' || TO_CHAR(pi_bus_date, 'YYYYMMDD') || '|' || pi_region, lv_error);
  write_rec(lf_archive, 'HDR|' || TO_CHAR(pi_bus_date, 'YYYYMMDD') || '|' || pi_region, lv_error);

  FOR r IN c_orders LOOP
    write_rec(lf_main, r.rec, lv_error);
    IF lv_error IS NOT NULL THEN
      po_status_code := -1;
      po_status_desc := lv_error;
      ln_lines := 0;
      GOTO finish;
    END IF;
    write_rec(lf_archive, r.rec, lv_error);
    ln_lines := ln_lines + 1;
  END LOOP;

  write_rec(lf_main, 'TRL|' || ln_lines, lv_error);
  write_rec(lf_archive, 'TRL|' || ln_lines, lv_error);

  <<finish>>
  IF ORAAS_UTL.IS_OPEN(lf_main) THEN
    ORAAS_UTL.FCLOSE(lf_main);
  END IF;
  IF ORAAS_UTL.IS_OPEN(lf_archive) THEN
    ORAAS_UTL.FCLOSE(lf_archive);
  END IF;

  IF ln_lines = 0 THEN
    ROLLBACK;
    BEGIN
      ORAAS_UTL.FREMOVE(pi_out_dir, lv_file_name);
      ORAAS_UTL.FREMOVE(pi_archive_dir, lv_file_name);
    EXCEPTION
      WHEN OTHERS THEN
        po_status_desc := po_status_desc || '; could not remove empty file';
    END;
  ELSE
    COMMIT;
  END IF;

  oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
EXCEPTION
  WHEN OTHERS THEN
    po_status_code := -1;
    po_status_desc := 'sales_order_export: ' || SQLERRM;
    IF ORAAS_UTL.IS_OPEN(lf_main) THEN
      ORAAS_UTL.FCLOSE(lf_main);
      ORAAS_UTL.FREMOVE(pi_out_dir, lv_file_name);
    END IF;
    oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
END sales_order_export;
/
