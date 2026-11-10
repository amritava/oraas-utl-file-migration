CREATE OR REPLACE PACKAGE oraas_utl_adapter AUTHID DEFINER IS
/* ============================================================================
   ORAAS_UTL_ADAPTER - the only place where your site's integration lives.
   ----------------------------------------------------------------------------
   ORAAS_UTL calls these hooks. Keep this specification unchanged; write your
   own package BODY (start from plsql/adapters/default_adapter.pkb) and keep
   it in your own repository. See references/adapter-guide.md.
   ============================================================================ */

  -- A converted unit finished successfully and this file is ready.
  -- The row in ORAAS_FILE_OUT is already committed. Deliver it now (e.g. call
  -- your hand-off procedure, write to object storage) or leave STATUS='READY'
  -- for an external poller. Raise to report failure: ORAAS_UTL then marks the
  -- row FAILED and raises ORA-20901 (ORAAS_UTL.HANDOFF_FAILED) in the unit.
  PROCEDURE on_file_ready(p_file_id IN NUMBER);

  -- PROCESSED_FLAG of one load of an input file changed (Y, E or N).
  -- Typical use: tell the loader where to archive the physical file.
  PROCEDURE on_input_marked(p_interface_code IN VARCHAR2,
                            p_file_name      IN VARCHAR2,
                            p_load_id        IN VARCHAR2,
                            p_flag           IN VARCHAR2,
                            p_how            IN VARCHAR2);

  -- TRUE when a legacy FRENAME/FCOPY destination means "error/reject folder".
  FUNCTION is_error_location(p_location IN VARCHAR2) RETURN BOOLEAN;

  -- Diagnostic message from ORAAS_UTL. Must never raise or commit the caller's work.
  PROCEDURE log(p_run_id IN NUMBER, p_message IN VARCHAR2);

END oraas_utl_adapter;
/
SHOW ERRORS
