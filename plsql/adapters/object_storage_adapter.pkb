CREATE OR REPLACE PACKAGE BODY oraas_utl_adapter IS
/* ============================================================================
   EXAMPLE adapter: writes each finished file to OCI Object Storage with
   DBMS_CLOUD.PUT_OBJECT, as UTF-8 without BOM, object name = location/file.
   Not used by the tests. Before use:
     - create a credential with DBMS_CLOUD.CREATE_CREDENTIAL;
     - set c_credential and c_base_uri below;
     - decide how input files are archived (on_input_marked).
   ============================================================================ */

  c_credential CONSTANT VARCHAR2(128)  := 'MY_OBJECT_STORE_CRED';               -- change
  c_base_uri   CONSTANT VARCHAR2(1000) :=
    'https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/';  -- change

  c_error_regex CONSTANT VARCHAR2(200) :=
    '(^|[^A-Z])(ERR|ERRS|ERROR|ERRORS|REJ|REJECT|REJECTS|REJECTED|FAIL|FAILED|FAILURE)([^A-Z]|$)';

  PROCEDURE set_status(p_file_id IN NUMBER, p_status IN VARCHAR2, p_text IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE oraas_file_out SET status = p_status, status_text = SUBSTR(p_text, 1, 4000)
     WHERE file_id = p_file_id;
    COMMIT;
  END set_status;

  PROCEDURE on_file_ready(p_file_id IN NUMBER) IS
    l_row    oraas_file_out%ROWTYPE;
    l_blob   BLOB;
    l_dest   INTEGER := 1;
    l_src    INTEGER := 1;
    l_lang   INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
    l_warn   INTEGER;
    l_object VARCHAR2(4000);
  BEGIN
    SELECT * INTO l_row FROM oraas_file_out WHERE file_id = p_file_id;
    DBMS_LOB.CREATETEMPORARY(l_blob, TRUE);
    IF l_row.content IS NOT NULL THEN
      DBMS_LOB.CONVERTTOBLOB(l_blob, l_row.content, DBMS_LOB.LOBMAXSIZE, l_dest, l_src,
                             NLS_CHARSET_ID('AL32UTF8'), l_lang, l_warn);
    END IF;
    l_object := REPLACE(TRIM(BOTH '/' FROM l_row.location) || '/' || l_row.file_name, '//', '/');
    DBMS_CLOUD.PUT_OBJECT(credential_name => c_credential,
                          object_uri      => c_base_uri || l_object,
                          contents        => l_blob);
    DBMS_LOB.FREETEMPORARY(l_blob);
    set_status(p_file_id, 'SENT', c_base_uri || l_object);
  END on_file_ready;

  PROCEDURE on_input_marked(p_interface_code IN VARCHAR2,
                            p_file_name      IN VARCHAR2,
                            p_load_id        IN VARCHAR2,
                            p_flag           IN VARCHAR2,
                            p_how            IN VARCHAR2) IS
  BEGIN
    NULL;   -- e.g. DBMS_CLOUD.MOVE_OBJECT from an inbox prefix to done/ or error/
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
      ROLLBACK;
  END log;

END oraas_utl_adapter;
/
SHOW ERRORS
