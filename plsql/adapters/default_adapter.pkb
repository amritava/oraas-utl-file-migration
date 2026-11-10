CREATE OR REPLACE PACKAGE BODY oraas_utl_adapter IS
/* ============================================================================
   Default adapter: no integration. Files stay in ORAAS_FILE_OUT with
   STATUS='READY'; input marks are only recorded in ORAAS_FILE_IN; messages go
   to ORAAS_FILE_LOG. Works out of the box and is what the tests use.
   Copy this file to your own repository to build your site adapter.
   ============================================================================ */

  -- Whole words only, so TRANSFERRED or REFERRAL are not error folders.
  c_error_regex CONSTANT VARCHAR2(200) :=
    '(^|[^A-Z])(ERR|ERRS|ERROR|ERRORS|REJ|REJECT|REJECTS|REJECTED|FAIL|FAILED|FAILURE)([^A-Z]|$)';

  PROCEDURE on_file_ready(p_file_id IN NUMBER) IS
  BEGIN
    NULL;   -- leave STATUS = 'READY' for an external poller
  END on_file_ready;

  PROCEDURE on_input_marked(p_interface_code IN VARCHAR2,
                            p_file_name      IN VARCHAR2,
                            p_load_id        IN VARCHAR2,
                            p_flag           IN VARCHAR2,
                            p_how            IN VARCHAR2) IS
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
    WHEN OTHERS THEN
      ROLLBACK;   -- logging must never break the business flow
  END log;

END oraas_utl_adapter;
/
SHOW ERRORS
