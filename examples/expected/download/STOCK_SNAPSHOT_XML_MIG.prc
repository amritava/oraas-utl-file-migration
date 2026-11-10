-- ORAAS_UTL_DOWNLOAD_GENERATED v1.0.0: UTL_FILE -> ORAAS_UTL; 1 frame(s). Compile and byte-compare before release.
CREATE OR REPLACE PROCEDURE stock_snapshot_xml (
    pi_out_dir     IN  VARCHAR2,
    pi_bus_date    IN  VARCHAR2,   -- DD/MM/YYYY
    po_err_code    OUT NUMBER,
    po_err_desc    OUT VARCHAR2) IS
      l_oraas_frame PLS_INTEGER;  -- ORAAS: file frame (generated)
/* -----------------------------------------------------------------------------
   INVENTED EXAMPLE (legacy). Never calls FCLOSE (legacy relied on the session
   end to close the file); an inner block swallows its own error and only sets
   the status; byte-exact text with trailing spaces in literals.
   ----------------------------------------------------------------------------- */
  lv_file   VARCHAR2(200);
  lv_rec    VARCHAR2(32000);
  f_xml     ORAAS_UTL.FILE_TYPE;
BEGIN
  l_oraas_frame := oraas_utl.begin_unit(
      p_unit_name     => 'STOCK_SNAPSHOT_XML',
      p_business_date => pi_bus_date);  -- ORAAS (generated)
  lv_file := 'stock_' || REPLACE(pi_bus_date, '/', '') || '.xml';
  f_xml := ORAAS_UTL.FOPEN(pi_out_dir, lv_file, 'W', 32767);
  ORAAS_UTL.PUT_LINE(f_xml, '<?xml version="1.0" encoding="utf-8" ?> ');
  BEGIN
    lv_rec := '<stock date="' || pi_bus_date || '">';
    lv_rec := lv_rec || CHR(10) || '<warehouse code="  ">';
    FOR w IN (SELECT item_code, qty FROM stock_levels ORDER BY item_code) LOOP
      lv_rec := lv_rec || CHR(10) || '<item code="' || w.item_code || '" qty="' || w.qty || '"/>';
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN
      po_err_code := 1;
      po_err_desc := 'stock_snapshot_xml: ' || SQLERRM;
  END;
  lv_rec := lv_rec || CHR(10) || '</warehouse>' || CHR(10) || '</stock>';
  ORAAS_UTL.PUT_LINE(f_xml, lv_rec);
  oraas_utl.end_unit(l_oraas_frame, (po_err_code IS NULL OR po_err_code = 0), p_submit_open => TRUE);
EXCEPTION
  WHEN ORAAS_UTL.INVALID_PATH THEN
    po_err_desc := 'Invalid path ' || pi_out_dir;
    oraas_utl.end_unit(l_oraas_frame, (po_err_code IS NULL OR po_err_code = 0), p_submit_open => TRUE);
  WHEN OTHERS THEN
    po_err_code := -1;
    po_err_desc := 'stock_snapshot_xml: ' || SQLERRM;
    oraas_utl.end_unit(l_oraas_frame, (po_err_code IS NULL OR po_err_code = 0), p_submit_open => TRUE);
END stock_snapshot_xml;
/
