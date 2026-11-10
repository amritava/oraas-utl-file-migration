-- =============================================================================
-- TEMPLATE (optional): replacement for a legacy "list the directory" procedure
-- -----------------------------------------------------------------------------
-- Many legacy upload units call a site-specific procedure (often a Java stored procedure)
-- that fills a table with the files of an OS folder, then loop over that table:
--
--     DELETE FROM my_dir_list_table;
--     my_dir_list_proc(l_folder);
--     FOR f IN (SELECT file_name, file_size FROM my_dir_list_table) LOOP ...
--
-- Replace ONLY that procedure, once, with the version below, so the legacy
-- loops keep working unchanged. Rename MY_DIR_LIST_PROC / MY_DIR_LIST_TABLE and
-- the column list to your real names IN YOUR OWN REPOSITORY, and list the
-- procedure name under "frame_trigger_calls" in config/upload_rules.json so the
-- converter frames units that call it.
-- =============================================================================
CREATE OR REPLACE PROCEDURE my_dir_list_proc (p_directory IN VARCHAR2) IS
BEGIN
  INSERT INTO my_dir_list_table (directory_name, file_name, file_size, last_modified)
  SELECT p_directory, f.file_name, f.file_size, f.loaded_at
    FROM TABLE(oraas_utl.list_input_files) f;     -- current unit, unprocessed files
END my_dir_list_proc;
/
SHOW ERRORS
