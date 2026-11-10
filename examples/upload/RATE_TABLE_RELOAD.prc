CREATE OR REPLACE PROCEDURE rate_table_reload (
    po_status_code OUT NUMBER) IS
/* -----------------------------------------------------------------------------
   INVENTED EXAMPLE (legacy). Reads one fixed input file and writes a reject
   file for invalid lines: both directions in one unit. Does not move the
   input file (expect warning NO_DISPOSITION).
   ----------------------------------------------------------------------------- */
  fin   UTL_FILE.FILE_TYPE;
  frej  UTL_FILE.FILE_TYPE;
  l     VARCHAR2(4000);
BEGIN
  po_status_code := 0;
  fin  := UTL_FILE.FOPEN('RATES_IN', 'rates.csv', 'r');
  frej := UTL_FILE.FOPEN('RATES_OUT', 'rates.rej', 'w');
  BEGIN
    LOOP
      UTL_FILE.GET_LINE(fin, l);
      IF REGEXP_LIKE(l, '^[A-Z]{3},[0-9.]+$') THEN
        MERGE INTO fx_rates t
        USING (SELECT SUBSTR(l, 1, 3) ccy, TO_NUMBER(SUBSTR(l, 5)) rate FROM dual) s
           ON (t.ccy = s.ccy)
         WHEN MATCHED THEN UPDATE SET t.rate = s.rate
         WHEN NOT MATCHED THEN INSERT (ccy, rate) VALUES (s.ccy, s.rate);
      ELSE
        UTL_FILE.PUT_LINE(frej, l);
      END IF;
    END LOOP;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN NULL;
  END;
  UTL_FILE.FCLOSE(fin);
  UTL_FILE.FCLOSE(frej);
  COMMIT;
END rate_table_reload;
/
