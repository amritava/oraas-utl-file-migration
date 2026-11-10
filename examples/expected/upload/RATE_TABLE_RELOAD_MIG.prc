-- ORAAS_UTL_UPLOAD_GENERATED v1.0.0: UTL_FILE -> ORAAS_UTL; 1 frame(s). Compile and byte-compare before release.
CREATE OR REPLACE PROCEDURE rate_table_reload (
    po_status_code OUT NUMBER,
    pi_session_id IN NUMBER DEFAULT NULL /* ORAAS Migration */) IS
      l_oraas_frame PLS_INTEGER;  -- ORAAS: file frame (generated)
/* -----------------------------------------------------------------------------
   INVENTED EXAMPLE (legacy). Reads one fixed input file and writes a reject
   file for invalid lines: both directions in one unit. Does not move the
   input file (expect warning NO_DISPOSITION).
   ----------------------------------------------------------------------------- */
  fin   ORAAS_UTL.FILE_TYPE;
  frej  ORAAS_UTL.FILE_TYPE;
  l     VARCHAR2(4000);
BEGIN
  l_oraas_frame := oraas_utl.begin_unit(
      p_unit_name  => 'RATE_TABLE_RELOAD',
      p_session_id => pi_session_id);  -- ORAAS (generated)
  po_status_code := 0;
  fin  := ORAAS_UTL.FOPEN('RATES_IN', 'rates.csv', 'r');
  frej := ORAAS_UTL.FOPEN('RATES_OUT', 'rates.rej', 'w');
  BEGIN
    LOOP
      ORAAS_UTL.GET_LINE(fin, l);
      IF REGEXP_LIKE(l, '^[A-Z]{3},[0-9.]+$') THEN
        MERGE INTO fx_rates t
        USING (SELECT SUBSTR(l, 1, 3) ccy, TO_NUMBER(SUBSTR(l, 5)) rate FROM dual) s
           ON (t.ccy = s.ccy)
         WHEN MATCHED THEN UPDATE SET t.rate = s.rate
         WHEN NOT MATCHED THEN INSERT (ccy, rate) VALUES (s.ccy, s.rate);
      ELSE
        ORAAS_UTL.PUT_LINE(frej, l);
      END IF;
    END LOOP;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;
  ORAAS_UTL.FCLOSE(fin);
  oraas_utl.mark_input(p_filename => 'rates.csv', p_session => pi_session_id, p_flag => CASE WHEN (po_status_code IS NULL OR po_status_code = 0) THEN 'Y' ELSE 'N' END, p_how => 'RATE_TABLE_RELOAD');  --ORAAS Migration
  ORAAS_UTL.FCLOSE(frej);
  COMMIT;
  oraas_utl.end_unit(l_oraas_frame, (po_status_code IS NULL OR po_status_code = 0));
EXCEPTION  -- ORAAS (generated): every exit must end the frame
  WHEN OTHERS THEN
    oraas_utl.end_unit(l_oraas_frame, FALSE);
    RAISE;
END rate_table_reload;
/
