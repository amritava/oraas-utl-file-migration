CREATE OR REPLACE PACKAGE oraas_utl AUTHID DEFINER IS
/* ============================================================================
   ORAAS_UTL  -  UTL_FILE-compatible shim for databases without UTL_FILE
                 (Oracle Autonomous Database / ORAAS)
   Version    :  1.0.0
   ----------------------------------------------------------------------------
   WHY THIS EXISTS
     Without a server file system and directory objects, UTL_FILE cannot be
     used. Converted program units call ORAAS_UTL instead of UTL_FILE. The
     calls, parameter names and exception codes are the same as UTL_FILE, so
     legacy logic (loops, wrappers, exception handlers) is kept unchanged.

   WRITING (download side)
     1. FOPEN/PUT/PUT_LINE/... write into an in-memory buffer owned by the
        calling program unit ("frame").
     2. FCLOSE marks the file complete. FREMOVE cancels it. FRENAME and FCOPY
        act on the buffer.
     3. When the unit exits, END_UNIT decides:
          p_ok = TRUE  : every closed, not-removed file is inserted into
                         ORAAS_FILE_OUT and ORAAS_UTL_ADAPTER.ON_FILE_READY is called.
          p_ok = FALSE : every file of the unit is discarded (a non-zero status
                         or an exception means no file).
        Files still open at END_UNIT are discarded unless p_submit_open is TRUE
        (legacy units that never call FCLOSE).

   READING (upload side)
     FOPEN(location, filename, 'r') serves the file from ORAAS_FILE_IN, loaded
     before the unit runs: INTERFACE_CODE (unit name in capitals, or
     p_interface_code of BEGIN_UNIT), FILE_NAME, and LOAD_ID = p_session_id of
     BEGIN_UNIT when given, else the oldest unprocessed load. GET_LINE returns
     lines in LINE_NO order and raises NO_DATA_FOUND at end of file, like
     UTL_FILE. MARK_INPUT (generated after FCLOSE) and FRENAME / FCOPY+FREMOVE
     of an input file set PROCESSED_FLAG (Y, or E for an error location), in
     their own transaction. The last mark for a load wins.
     LIST_INPUT_FILES lists the unprocessed input files of the current unit.

   GENERATED CALLS (inserted by scripts/oraas_convert.py)
     l_oraas_frame := oraas_utl.begin_unit(p_unit_name => 'MY_PROC', ...);
     ...
     oraas_utl.end_unit(l_oraas_frame, (PO_ERR_CODE IS NULL OR PO_ERR_CODE = 0));

   NOT SUPPORTED (raise INVALID_OPERATION; the converter refuses these units)
     Byte mode ('rb', 'wb', 'ab', GET_RAW, PUT_RAW) and FSEEK.

   DEPENDENCIES
     01_oraas_file_tables.sql, ORAAS_UTL_ADAPTER (spec + one body),
     UTL_CALL_STACK (12c+).
   ============================================================================ */

  c_version CONSTANT VARCHAR2(10) := '1.0.0';

  -- Same shape as UTL_FILE.FILE_TYPE so declarations and handle passing work unchanged.
  TYPE file_type IS RECORD (
    id        BINARY_INTEGER,
    datatype  BINARY_INTEGER,
    byte_mode BOOLEAN);

  -- Same error codes as UTL_FILE: legacy handlers (WHEN ORAAS_UTL.WRITE_ERROR,
  -- SQLCODE checks) keep their meaning.
  invalid_path        EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_path,        -29280);
  invalid_mode        EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_mode,        -29281);
  invalid_filehandle  EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_filehandle,  -29282);
  invalid_operation   EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_operation,   -29283);
  read_error          EXCEPTION; PRAGMA EXCEPTION_INIT(read_error,          -29284);
  write_error         EXCEPTION; PRAGMA EXCEPTION_INIT(write_error,         -29285);
  internal_error      EXCEPTION; PRAGMA EXCEPTION_INIT(internal_error,      -29286);
  invalid_maxlinesize EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_maxlinesize, -29287);
  invalid_filename    EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_filename,    -29288);
  access_denied       EXCEPTION; PRAGMA EXCEPTION_INIT(access_denied,       -29289);
  invalid_offset      EXCEPTION; PRAGMA EXCEPTION_INIT(invalid_offset,      -29290);
  delete_failed       EXCEPTION; PRAGMA EXCEPTION_INIT(delete_failed,       -29291);
  rename_failed       EXCEPTION; PRAGMA EXCEPTION_INIT(rename_failed,       -29292);
  charsetmismatch     EXCEPTION; PRAGMA EXCEPTION_INIT(charsetmismatch,     -29298);
  -- UTL_FILE.FILE_OPEN exists in UTL_FILE; declared so renamed handlers compile.
  -- The shim never raises it.
  file_open           EXCEPTION;
  -- Raised by END_UNIT when the adapter's ON_FILE_READY fails.
  handoff_failed      EXCEPTION; PRAGMA EXCEPTION_INIT(handoff_failed,      -20901);

  -- ---------------------------------------------------------------- frames
  -- p_session_id    : load id of the input files to read (upload side), or NULL.
  -- p_business_date : free text stored with every output file.
  -- p_context       : NAME=value; pairs built by the converter from unit parameters.
  FUNCTION begin_unit(
    p_unit_name      IN VARCHAR2,
    p_interface_code IN VARCHAR2 DEFAULT NULL,
    p_session_id     IN VARCHAR2 DEFAULT NULL,
    p_business_date  IN VARCHAR2 DEFAULT NULL,
    p_context        IN VARCHAR2 DEFAULT NULL)
  RETURN PLS_INTEGER;

  -- Interface code of the innermost active converted unit (raises outside one).
  FUNCTION current_interface RETURN VARCHAR2;

  -- Load id (ORAAS_FILE_IN.LOAD_ID) passed to BEGIN_UNIT, or NULL.
  FUNCTION current_session RETURN VARCHAR2;

  -- Sets PROCESSED_FLAG ('Y' processed, 'E' error, 'N' not processed) of one load of
  -- an input file, committed at once. p_session NULL: the load being read in this
  -- call. The last call for a load wins. Generated after every FCLOSE of an input file.
  PROCEDURE mark_input(p_filename IN VARCHAR2,
                       p_session  IN VARCHAR2 DEFAULT NULL,
                       p_flag     IN VARCHAR2 DEFAULT 'Y',
                       p_how      IN VARCHAR2 DEFAULT NULL);

  -- Unprocessed input files of the current unit (current load only when a
  -- session/load id was passed to BEGIN_UNIT). FILE_SIZE = bytes + 1 per line.
  TYPE input_file_rec IS RECORD (
    file_name  VARCHAR2(1000),
    file_size  NUMBER,
    loaded_at  DATE,
    load_id    VARCHAR2(256));
  TYPE input_file_tab IS TABLE OF input_file_rec;
  FUNCTION list_input_files RETURN input_file_tab PIPELINED;

  PROCEDURE end_unit(
    p_frame       IN PLS_INTEGER,
    p_ok          IN BOOLEAN,
    p_submit_open IN BOOLEAN DEFAULT FALSE);

  -- Operations support: drops every frame and buffer of this DB session.
  PROCEDURE reset_session;

  -- Diagnostics: one line describing frames and buffered files.
  FUNCTION state_summary RETURN VARCHAR2;

  -- ------------------------------------------------- UTL_FILE-compatible API
  FUNCTION fopen(
    location     IN VARCHAR2,
    filename     IN VARCHAR2,
    open_mode    IN VARCHAR2,
    max_linesize IN BINARY_INTEGER DEFAULT 1024)
  RETURN file_type;

  FUNCTION fopen_nchar(
    location     IN VARCHAR2,
    filename     IN VARCHAR2,
    open_mode    IN VARCHAR2,
    max_linesize IN BINARY_INTEGER DEFAULT 1024)
  RETURN file_type;

  FUNCTION  is_open(file IN file_type) RETURN BOOLEAN;
  PROCEDURE get_line(file IN file_type, buffer OUT VARCHAR2, len IN BINARY_INTEGER DEFAULT NULL);
  PROCEDURE get_line_nchar(file IN file_type, buffer OUT NVARCHAR2, len IN BINARY_INTEGER DEFAULT NULL);
  PROCEDURE fclose(file IN OUT file_type);
  PROCEDURE fclose_all;
  PROCEDURE fflush(file IN file_type);

  PROCEDURE put(file IN file_type, buffer IN VARCHAR2);
  PROCEDURE put_line(file IN file_type, buffer IN VARCHAR2, autoflush IN BOOLEAN DEFAULT FALSE);
  PROCEDURE new_line(file IN file_type, lines IN NATURAL := 1);
  PROCEDURE putf(file   IN file_type,
                 format IN VARCHAR2,
                 arg1   IN VARCHAR2 DEFAULT NULL,
                 arg2   IN VARCHAR2 DEFAULT NULL,
                 arg3   IN VARCHAR2 DEFAULT NULL,
                 arg4   IN VARCHAR2 DEFAULT NULL,
                 arg5   IN VARCHAR2 DEFAULT NULL);

  PROCEDURE put_nchar(file IN file_type, buffer IN NVARCHAR2);
  PROCEDURE put_line_nchar(file IN file_type, buffer IN NVARCHAR2);
  PROCEDURE putf_nchar(file   IN file_type,
                       format IN NVARCHAR2,
                       arg1   IN NVARCHAR2 DEFAULT NULL,
                       arg2   IN NVARCHAR2 DEFAULT NULL,
                       arg3   IN NVARCHAR2 DEFAULT NULL,
                       arg4   IN NVARCHAR2 DEFAULT NULL,
                       arg5   IN NVARCHAR2 DEFAULT NULL);

  -- These act on files produced in this DB session only. A file that is not
  -- in the session buffer (e.g. produced by an earlier job) is NOT touched:
  -- the call is logged and ignored. The converter flags every such call.
  PROCEDURE fremove(location IN VARCHAR2, filename IN VARCHAR2);
  PROCEDURE frename(src_location  IN VARCHAR2,
                    src_filename  IN VARCHAR2,
                    dest_location IN VARCHAR2,
                    dest_filename IN VARCHAR2,
                    overwrite     IN BOOLEAN DEFAULT FALSE);
  PROCEDURE fcopy(src_location  IN VARCHAR2,
                  src_filename  IN VARCHAR2,
                  dest_location IN VARCHAR2,
                  dest_filename IN VARCHAR2,
                  start_line    IN BINARY_INTEGER DEFAULT 1,
                  end_line      IN BINARY_INTEGER DEFAULT NULL);
  PROCEDURE fgetattr(location    IN VARCHAR2,
                     filename    IN VARCHAR2,
                     fexists     OUT BOOLEAN,
                     file_length OUT NUMBER,
                     block_size  OUT BINARY_INTEGER);
  FUNCTION  fgetpos(file IN file_type) RETURN PLS_INTEGER;

END oraas_utl;
/
SHOW ERRORS
