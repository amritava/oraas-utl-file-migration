CREATE OR REPLACE PACKAGE BODY oraas_utl_adapter IS
/* TEST adapter used by the SQL unit tests only. Same as the default adapter,
   except ON_FILE_READY fails for file names starting with FAIL. */
  c_error_regex CONSTANT VARCHAR2(200) :=
    '(^|[^A-Z])(ERR|ERRS|ERROR|ERRORS|REJ|REJECT|REJECTS|REJECTED|FAIL|FAILED|FAILURE)([^A-Z]|$)';

  PROCEDURE on_file_ready(p_file_id IN NUMBER) IS
    l_name oraas_file_out.file_name%TYPE;
  BEGIN
    SELECT file_name INTO l_name FROM oraas_file_out WHERE file_id = p_file_id;
    IF l_name LIKE 'FAIL%' THEN
      RAISE_APPLICATION_ERROR(-20999, 'test adapter: delivery failed');
    END IF;
  END on_file_ready;

  PROCEDURE on_input_marked(p_interface_code IN VARCHAR2, p_file_name IN VARCHAR2,
                            p_load_id IN VARCHAR2, p_flag IN VARCHAR2, p_how IN VARCHAR2) IS
  BEGIN
    NULL;
  END on_input_marked;

  FUNCTION is_error_location(p_location IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN REGEXP_LIKE(UPPER(p_location), c_error_regex);
  END is_error_location;

  PROCEDURE log(p_run_id IN NUMBER, p_message IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO oraas_file_log (run_id, message) VALUES (p_run_id, SUBSTR(p_message, 1, 4000));
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN ROLLBACK;
  END log;
END oraas_utl_adapter;
/
SHOW ERRORS
