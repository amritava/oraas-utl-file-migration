CREATE OR REPLACE PACKAGE BODY oraas_utl IS
/* ============================================================================
   ORAAS_UTL body - see the specification for the contract.
   Session-level state:
     g_frames : stack of active converted program units (one per invocation)
     g_files  : every buffered file, tagged with the frame that owns it
   Byte rules (identical to UTL_FILE text mode on a Unix host):
     PUT       -> text
     PUT_LINE  -> text || c_terminator
     NEW_LINE  -> c_terminator x lines
     PUTF      -> '%s' replaced by arg1..arg5 (missing -> empty), '\n' -> c_terminator
     FCLOSE    -> nothing added
   Upload (read) side:
     g_reads  : input files opened with mode 'r'. Lines are served from
                ORAAS_FILE_IN in LINE_NO order, in chunks.
     An input file is identified by INTERFACE_CODE (= converted unit name in
     capitals, from BEGIN_UNIT) + FILE_NAME + LOAD_ID (given, or oldest unprocessed).
     FRENAME/FCOPY+FREMOVE of an input file record where legacy moved it:
     PROCESSED_FLAG 'E' (error folder) or 'Y' (any other folder), committed
     immediately in its own transaction, as a legacy file move was.
   ============================================================================ */

  -- Line terminator written by legacy UTL_FILE on the legacy DB host.
  -- Unix/Linux host = CHR(10). Change to CHR(13)||CHR(10) only if the legacy
  -- database server ran on Windows.
  c_terminator CONSTANT VARCHAR2(2) := CHR(10);

  -- Bytes kept in the VARCHAR2 staging buffer before one LOB append.
  c_stage_max  CONSTANT PLS_INTEGER := 32000;

  c_open    CONSTANT VARCHAR2(8) := 'OPEN';
  c_closed  CONSTANT VARCHAR2(8) := 'CLOSED';
  c_ropen   CONSTANT VARCHAR2(8) := 'ROPEN';    -- removed while still open
  c_removed CONSTANT VARCHAR2(8) := 'REMOVED';

  -- Upload side -------------------------------------------------------------
  c_read_chunk CONSTANT PLS_INTEGER := 1000;   -- raw rows fetched per round trip
  -- TRUE: a line longer than FOPEN max_linesize raises READ_ERROR (ORA-29284),
  -- as legacy UTL_FILE did. Set FALSE only after confirming no unit relies on it.
  c_enforce_read_linesize CONSTANT BOOLEAN := TRUE;
  -- Whether a destination is an error folder is decided by
  -- ORAAS_UTL_ADAPTER.IS_ERROR_LOCATION.

  TYPE line_tab IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
  TYPE read_rec IS RECORD (
    frame_id      PLS_INTEGER,
    state         VARCHAR2(8),
    closed_by_all BOOLEAN,
    location      VARCHAR2(4000),
    filename      VARCHAR2(4000),
    interface     VARCHAR2(100),
    session_id    VARCHAR2(256),
    max_linesize  PLS_INTEGER,
    last_line_no  NUMBER,
    lines         line_tab,
    line_idx      PLS_INTEGER,
    eof           BOOLEAN,
    remainder     VARCHAR2(32767),
    bytes_read    NUMBER);
  TYPE read_tab IS TABLE OF read_rec INDEX BY PLS_INTEGER;
  TYPE pending_tab IS TABLE OF VARCHAR2(1) INDEX BY VARCHAR2(500);
  TYPE marked_tab  IS TABLE OF VARCHAR2(256) INDEX BY VARCHAR2(500);

  g_reads      read_tab;
  g_pending    pending_tab;        -- FCOPY of an input file: flag to apply at FREMOVE
  g_marked     marked_tab;         -- interface|file -> load (LOAD_ID) marked in this call

  TYPE file_rec IS RECORD (
    frame_id      PLS_INTEGER,
    state         VARCHAR2(8),
    closed_by_all BOOLEAN,
    location      VARCHAR2(4000),
    filename      VARCHAR2(4000),
    open_mode     VARCHAR2(4),
    buf           CLOB,
    stage         VARCHAR2(32767),
    bytes         NUMBER,
    close_seq     PLS_INTEGER);
  TYPE file_tab IS TABLE OF file_rec INDEX BY PLS_INTEGER;

  TYPE frame_rec IS RECORD (
    frame_id      PLS_INTEGER,
    depth         PLS_INTEGER,
    owner         VARCHAR2(4000),
    unit_name     VARCHAR2(4000),
    busi_dt       VARCHAR2(30),
    context       VARCHAR2(4000),
    interface     VARCHAR2(128),
    session_id    VARCHAR2(256));
  TYPE frame_tab IS TABLE OF frame_rec INDEX BY PLS_INTEGER;

  g_files      file_tab;
  g_frames     frame_tab;          -- stack, index 1..g_top
  g_top        PLS_INTEGER := 0;
  g_next_file  PLS_INTEGER := 0;
  g_next_frame PLS_INTEGER := 0;
  g_close_seq  PLS_INTEGER := 0;
  g_session_id NUMBER;             -- run id: one per outermost frame, from ORAAS_RUN_SEQ, allocated lazily

  ------------------------------------------------------------------ logging
  -- The adapter owns the destination; it must not commit the caller's work.
  PROCEDURE write_log(p_msg IN VARCHAR2) IS
  BEGIN
    oraas_utl_adapter.log(g_session_id, SUBSTR('ORAAS_UTL: ' || p_msg, 1, 3900));
  EXCEPTION
    WHEN OTHERS THEN
      NULL;      -- logging must never break the business flow
  END write_log;

  FUNCTION frame_label(p_k IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN g_frames(p_k).unit_name || '#' || g_frames(p_k).frame_id;
  END frame_label;

  ----------------------------------------------------------- buffer helpers
  PROCEDURE free_buf(p_id IN PLS_INTEGER) IS
  BEGIN
    IF g_files(p_id).buf IS NOT NULL
       AND DBMS_LOB.ISTEMPORARY(g_files(p_id).buf) = 1 THEN
      DBMS_LOB.FREETEMPORARY(g_files(p_id).buf);
    END IF;
    g_files(p_id).buf   := NULL;
    g_files(p_id).stage := NULL;
  EXCEPTION
    WHEN OTHERS THEN
      g_files(p_id).buf   := NULL;
      g_files(p_id).stage := NULL;
  END free_buf;

  PROCEDURE drop_file(p_id IN PLS_INTEGER) IS
  BEGIN
    IF g_files.EXISTS(p_id) THEN
      free_buf(p_id);
      g_files.DELETE(p_id);
    END IF;
  END drop_file;

  PROCEDURE flush_stage(p_id IN PLS_INTEGER) IS
  BEGIN
    IF g_files(p_id).stage IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(g_files(p_id).buf,
                           LENGTH(g_files(p_id).stage),
                           g_files(p_id).stage);
      g_files(p_id).stage := NULL;
    END IF;
  END flush_stage;

  -- Appends text exactly as given. Byte count uses the DB charset
  -- (AL32UTF8 = the UTF-8 bytes legacy UTL_FILE wrote).
  PROCEDURE append_text(p_id IN PLS_INTEGER, p_text IN VARCHAR2) IS
    l_len PLS_INTEGER;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    l_len := LENGTHB(p_text);
    IF NVL(LENGTHB(g_files(p_id).stage), 0) + l_len > c_stage_max THEN
      flush_stage(p_id);
    END IF;
    IF l_len > c_stage_max THEN
      DBMS_LOB.WRITEAPPEND(g_files(p_id).buf, LENGTH(p_text), p_text);
    ELSE
      g_files(p_id).stage := g_files(p_id).stage || p_text;
    END IF;
    g_files(p_id).bytes := g_files(p_id).bytes + l_len;
  END append_text;

  -- NVARCHAR2 input is converted in whole-character chunks (no split
  -- surrogate pairs). AL32UTF8 holds every NCHAR character, so this is lossless.
  PROCEDURE append_nchar(p_id IN PLS_INTEGER, p_text IN NVARCHAR2) IS
    c_chunk CONSTANT PLS_INTEGER := 4000;
    l_pos   PLS_INTEGER := 1;
    l_len   PLS_INTEGER;
  BEGIN
    IF p_text IS NULL THEN
      RETURN;
    END IF;
    l_len := LENGTHC(p_text);
    WHILE l_pos <= l_len LOOP
      append_text(p_id, TO_CHAR(SUBSTRC(p_text, l_pos, c_chunk)));
      l_pos := l_pos + c_chunk;
    END LOOP;
  END append_nchar;

  ------------------------------------------------------------ frame helpers
  FUNCTION frame_index(p_frame IN PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    IF p_frame IS NULL THEN
      RETURN NULL;
    END IF;
    FOR k IN REVERSE 1 .. g_top LOOP
      IF g_frames(k).frame_id = p_frame THEN
        RETURN k;
      END IF;
    END LOOP;
    RETURN NULL;
  END frame_index;

  -- Discards every file owned by frame k (no submission).
  FUNCTION discard_frame_files(p_k IN PLS_INTEGER) RETURN PLS_INTEGER IS
    l_id    PLS_INTEGER;
    l_next  PLS_INTEGER;
    l_count PLS_INTEGER := 0;
  BEGIN
    l_id := g_files.FIRST;
    WHILE l_id IS NOT NULL LOOP
      l_next := g_files.NEXT(l_id);
      IF g_files(l_id).frame_id = g_frames(p_k).frame_id THEN
        IF g_files(l_id).state IN (c_open, c_closed) THEN
          l_count := l_count + 1;
        END IF;
        drop_file(l_id);
      END IF;
      l_id := l_next;
    END LOOP;
    RETURN l_count;
  END discard_frame_files;

  PROCEDURE drop_frame_reads(p_frame_id IN PLS_INTEGER) IS
    l_id   PLS_INTEGER;
    l_next PLS_INTEGER;
  BEGIN
    l_id := g_reads.FIRST;
    WHILE l_id IS NOT NULL LOOP
      l_next := g_reads.NEXT(l_id);
      IF g_reads(l_id).frame_id = p_frame_id THEN
        g_reads.DELETE(l_id);
      END IF;
      l_id := l_next;
    END LOOP;
  END drop_frame_reads;

  -- Pops frames g_top .. p_k, discarding whatever they still hold.
  PROCEDURE pop_to(p_k IN PLS_INTEGER) IS
    l_n PLS_INTEGER;
  BEGIN
    WHILE g_top >= p_k AND g_top > 0 LOOP
      drop_frame_reads(g_frames(g_top).frame_id);
      l_n := discard_frame_files(g_top);
      IF l_n > 0 THEN
        write_log('discarded ' || l_n || ' unsubmitted file(s) of ' || frame_label(g_top));
      END IF;
      g_frames.DELETE(g_top);
      g_top := g_top - 1;
    END LOOP;
    IF g_top = 0 THEN
      g_session_id := NULL;
      g_pending.DELETE;
      g_marked.DELETE;
    END IF;
  END pop_to;

  FUNCTION top_frame_id RETURN PLS_INTEGER IS
  BEGIN
    IF g_top = 0 THEN
      write_log('file operation outside a converted unit (no BEGIN_UNIT frame)');
      RAISE invalid_operation;
    END IF;
    RETURN g_frames(g_top).frame_id;
  END top_frame_id;

  ------------------------------------------------------------- file lookup
  -- Latest live (OPEN or CLOSED) file with this location/name, any frame.
  FUNCTION find_file(p_location IN VARCHAR2, p_filename IN VARCHAR2)
  RETURN PLS_INTEGER IS
    l_id PLS_INTEGER;
  BEGIN
    l_id := g_files.LAST;
    WHILE l_id IS NOT NULL LOOP
      IF g_files(l_id).state IN (c_open, c_closed)
         AND UPPER(TRIM(g_files(l_id).location)) = UPPER(TRIM(p_location))
         AND g_files(l_id).filename = p_filename THEN
        RETURN l_id;
      END IF;
      l_id := g_files.PRIOR(l_id);
    END LOOP;
    RETURN NULL;
  END find_file;

  FUNCTION handle_id(p_file IN file_type) RETURN PLS_INTEGER IS
  BEGIN
    IF p_file.id IS NULL OR NOT g_files.EXISTS(p_file.id) THEN
      RAISE invalid_filehandle;
    END IF;
    RETURN p_file.id;
  END handle_id;

  FUNCTION writable_id(p_file IN file_type) RETURN PLS_INTEGER IS
    l_id PLS_INTEGER := handle_id(p_file);
  BEGIN
    IF g_files(l_id).state NOT IN (c_open, c_ropen) THEN
      RAISE invalid_filehandle;
    END IF;
    RETURN l_id;
  END writable_id;

  FUNCTION new_file(p_location IN VARCHAR2, p_filename IN VARCHAR2,
                    p_mode IN VARCHAR2, p_state IN VARCHAR2)
  RETURN PLS_INTEGER IS
    l_id PLS_INTEGER;
  BEGIN
    g_next_file := g_next_file + 1;
    l_id := g_next_file;
    g_files(l_id).frame_id      := top_frame_id;
    g_files(l_id).state         := p_state;
    g_files(l_id).closed_by_all := FALSE;
    g_files(l_id).location      := p_location;
    g_files(l_id).filename      := p_filename;
    g_files(l_id).open_mode     := p_mode;
    g_files(l_id).bytes         := 0;
    g_files(l_id).stage         := NULL;
    DBMS_LOB.CREATETEMPORARY(g_files(l_id).buf, TRUE, DBMS_LOB.SESSION);
    IF p_state = c_closed THEN
      g_close_seq := g_close_seq + 1;
      g_files(l_id).close_seq := g_close_seq;
    END IF;
    RETURN l_id;
  END new_file;

  -------------------------------------------------------------- submission
  PROCEDURE set_out_status(p_file_id IN NUMBER, p_status IN VARCHAR2, p_text IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE oraas_file_out SET status = p_status, status_text = SUBSTR(p_text, 1, 4000)
     WHERE file_id = p_file_id;
    COMMIT;
  END set_out_status;

  -- Stores the file (own transaction, like a file written to disk) and calls the adapter.
  PROCEDURE submit_file(p_id IN PLS_INTEGER, p_k IN PLS_INTEGER) IS
    l_file_id NUMBER;
    l_err     VARCHAR2(4000);
    PROCEDURE store IS
      PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
      INSERT INTO oraas_file_out (run_id, unit_name, interface_code, location, file_name,
                                  business_date, context, content, byte_count, is_empty)
      VALUES (g_session_id, g_frames(p_k).unit_name, g_frames(p_k).interface,
              g_files(p_id).location, g_files(p_id).filename,
              g_frames(p_k).busi_dt, g_frames(p_k).context,
              CASE WHEN g_files(p_id).bytes = 0 THEN NULL ELSE TO_NCLOB(g_files(p_id).buf) END,
              g_files(p_id).bytes,
              CASE WHEN g_files(p_id).bytes = 0 THEN 'Y' ELSE 'N' END)
      RETURNING file_id INTO l_file_id;
      COMMIT;
    END store;
  BEGIN
    flush_stage(p_id);
    IF g_session_id IS NULL THEN
      SELECT oraas_run_seq.NEXTVAL INTO g_session_id FROM dual;
    END IF;
    store;
    BEGIN
      oraas_utl_adapter.on_file_ready(l_file_id);
    EXCEPTION
      WHEN OTHERS THEN
        l_err := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 1800);
        set_out_status(l_file_id, 'FAILED', l_err);
        RAISE_APPLICATION_ERROR(-20901,
          SUBSTR('ORAAS_UTL: adapter could not deliver ' || g_files(p_id).location || '/' ||
                 g_files(p_id).filename || ' (file_id ' || l_file_id || '): ' || l_err, 1, 2000));
    END;
    write_log('stored ' || g_files(p_id).location || '/' || g_files(p_id).filename ||
        ' file_id=' || l_file_id || ' bytes=' || g_files(p_id).bytes ||
        ' run=' || g_session_id || ' unit=' || frame_label(p_k));
  END submit_file;

  -- ============================================================ frames API
  FUNCTION begin_unit(
    p_unit_name      IN VARCHAR2,
    p_interface_code IN VARCHAR2 DEFAULT NULL,
    p_session_id     IN VARCHAR2 DEFAULT NULL,
    p_business_date  IN VARCHAR2 DEFAULT NULL,
    p_context        IN VARCHAR2 DEFAULT NULL)
  RETURN PLS_INTEGER IS
    l_depth PLS_INTEGER;
    l_owner VARCHAR2(4000);
    l_stale PLS_INTEGER;
    l_idx   PLS_INTEGER;
  BEGIN
    -- Call-stack position of the caller. Used to detect frames left behind by
    -- an earlier invocation that ended without END_UNIT (e.g. an error raised
    -- inside an exception handler). A live ancestor frame is always shallower
    -- and its owner is still on the stack at the same level.
    -- Everything is evaluated inline here: calling a helper would add a level.
    BEGIN
      l_depth := UTL_CALL_STACK.DYNAMIC_DEPTH;
      l_owner := UTL_CALL_STACK.CONCATENATE_SUBPROGRAM(UTL_CALL_STACK.SUBPROGRAM(2));
      FOR k IN 1 .. g_top LOOP
        IF g_frames(k).depth IS NULL OR g_frames(k).depth >= l_depth THEN
          l_stale := k;
        ELSE
          l_idx := l_depth - g_frames(k).depth + 2;
          IF NVL(UTL_CALL_STACK.CONCATENATE_SUBPROGRAM(UTL_CALL_STACK.SUBPROGRAM(l_idx)), '?')
             <> NVL(g_frames(k).owner, '?') THEN
            l_stale := k;
          END IF;
        END IF;
        EXIT WHEN l_stale IS NOT NULL;
      END LOOP;
    EXCEPTION
      WHEN OTHERS THEN
        l_depth := NULL;     -- stale detection unavailable; keep the stack
        l_owner := NULL;
        l_stale := NULL;
    END;

    IF l_stale IS NOT NULL THEN
      write_log('stale frame(s) from an earlier invocation found below ' || p_unit_name ||
          ' (first: ' || frame_label(l_stale) || '); discarding');
      pop_to(l_stale);
    END IF;

    g_next_frame := g_next_frame + 1;
    g_top := g_top + 1;
    g_frames(g_top).frame_id      := g_next_frame;
    g_frames(g_top).depth         := l_depth;
    g_frames(g_top).owner         := l_owner;
    g_frames(g_top).unit_name     := p_unit_name;
    g_frames(g_top).busi_dt       := p_business_date;
    g_frames(g_top).context       := p_context;
    g_frames(g_top).interface     := UPPER(NVL(p_interface_code, p_unit_name));
    g_frames(g_top).session_id    := p_session_id;
    RETURN g_next_frame;
  END begin_unit;

  PROCEDURE end_unit(
    p_frame       IN PLS_INTEGER,
    p_ok          IN BOOLEAN,
    p_submit_open IN BOOLEAN DEFAULT FALSE) IS
    l_k     PLS_INTEGER;
    l_id    PLS_INTEGER;
    l_next  PLS_INTEGER;
    l_pick  PLS_INTEGER;
    l_fid   PLS_INTEGER;
    l_ok    BOOLEAN := NVL(p_ok, FALSE);
    l_count PLS_INTEGER := 0;
    l_label VARCHAR2(4000);
    l_err   VARCHAR2(4000);
  BEGIN
    l_k := frame_index(p_frame);
    IF l_k IS NULL THEN
      RETURN;                -- already ended (second exit path) or never begun
    END IF;
    l_label := frame_label(l_k);
    l_fid   := g_frames(l_k).frame_id;

    IF l_k < g_top THEN
      write_log('inner frame(s) above ' || l_label || ' were not ended; discarding them');
      pop_to(l_k + 1);
    END IF;

    BEGIN
      -- 1. files still open at unit exit
      l_id := g_files.FIRST;
      WHILE l_id IS NOT NULL LOOP
        l_next := g_files.NEXT(l_id);
        IF g_files(l_id).frame_id = l_fid THEN
          IF g_files(l_id).state = c_open AND l_ok AND NVL(p_submit_open, FALSE) THEN
            -- legacy unit never calls FCLOSE: the session-end close kept the file
            flush_stage(l_id);
            g_files(l_id).state := c_closed;
            g_close_seq := g_close_seq + 1;
            g_files(l_id).close_seq := g_close_seq;
          ELSIF g_files(l_id).state = c_open THEN
            write_log('file still open at end of ' || l_label || ', discarded: ' ||
                g_files(l_id).location || '/' || g_files(l_id).filename);
            drop_file(l_id);
          ELSIF g_files(l_id).state IN (c_ropen, c_removed) THEN
            drop_file(l_id);
          END IF;
        END IF;
        l_id := l_next;
      END LOOP;

      -- 2. success gate: unit reported failure -> no files
      IF NOT l_ok THEN
        l_id := g_files.FIRST;
        WHILE l_id IS NOT NULL LOOP
          IF g_files(l_id).frame_id = l_fid THEN
            l_count := l_count + 1;
          END IF;
          l_id := g_files.NEXT(l_id);
        END LOOP;
        IF l_count > 0 THEN
          write_log(l_label || ' ended with failure status; ' || l_count ||
              ' file(s) discarded, nothing submitted');
        END IF;
        pop_to(l_k);
        RETURN;
      END IF;

      -- 3. submit closed files in FCLOSE order
      LOOP
        l_pick := NULL;
        l_id := g_files.FIRST;
        WHILE l_id IS NOT NULL LOOP
          IF g_files(l_id).frame_id = l_fid AND g_files(l_id).state = c_closed
             AND (l_pick IS NULL OR g_files(l_id).close_seq < g_files(l_pick).close_seq) THEN
            l_pick := l_id;
          END IF;
          l_id := g_files.NEXT(l_id);
        END LOOP;
        EXIT WHEN l_pick IS NULL;
        submit_file(l_pick, l_k);
        drop_file(l_pick);
      END LOOP;

      pop_to(l_k);
    EXCEPTION
      WHEN OTHERS THEN
        l_err := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 1, 1800);
        pop_to(l_k);         -- remaining files are discarded, state is clean
        write_log('END_UNIT failed for ' || l_label || ': ' || l_err);
        RAISE_APPLICATION_ERROR(-20901,
          SUBSTR('ORAAS_UTL: download hand-off failed in ' || l_label || ': ' || l_err, 1, 2000));
    END;
  END end_unit;

  PROCEDURE reset_session IS
    l_id PLS_INTEGER;
  BEGIN
    pop_to(1);
    l_id := g_files.FIRST;
    WHILE l_id IS NOT NULL LOOP
      free_buf(l_id);
      l_id := g_files.NEXT(l_id);
    END LOOP;
    g_files.DELETE;
    g_reads.DELETE;
    g_pending.DELETE;
    g_marked.DELETE;
    g_session_id := NULL;
  END reset_session;

  FUNCTION state_summary RETURN VARCHAR2 IS
    l_txt VARCHAR2(32767);
    l_id  PLS_INTEGER;
  BEGIN
    l_txt := 'frames=' || g_top || ' session=' || NVL(TO_CHAR(g_session_id), '-');
    FOR k IN 1 .. g_top LOOP
      l_txt := l_txt || ' [' || frame_label(k) || ']';
    END LOOP;
    l_id := g_files.FIRST;
    WHILE l_id IS NOT NULL AND LENGTH(l_txt) < 30000 LOOP
      l_txt := l_txt || ' {' || l_id || ':' || g_files(l_id).state || ':' ||
               g_files(l_id).location || '/' || g_files(l_id).filename || ':' ||
               g_files(l_id).bytes || 'B}';
      l_id := g_files.NEXT(l_id);
    END LOOP;
    l_id := g_reads.FIRST;
    WHILE l_id IS NOT NULL AND LENGTH(l_txt) < 30000 LOOP
      l_txt := l_txt || ' {' || l_id || ':R-' || g_reads(l_id).state || ':' ||
               g_reads(l_id).interface || '/' || g_reads(l_id).filename || ':line>' ||
               g_reads(l_id).last_line_no || '}';
      l_id := g_reads.NEXT(l_id);
    END LOOP;
    RETURN l_txt;
  END state_summary;

  -- =========================================================== upload side
  FUNCTION current_interface RETURN VARCHAR2 IS
  BEGIN
    IF g_top = 0 THEN
      write_log('upload operation outside a converted unit (no BEGIN_UNIT frame)');
      RAISE invalid_operation;
    END IF;
    RETURN g_frames(g_top).interface;
  END current_interface;

  FUNCTION current_session RETURN VARCHAR2 IS
  BEGIN
    IF g_top = 0 THEN
      RETURN NULL;
    END IF;
    RETURN g_frames(g_top).session_id;
  END current_session;

  -- Load (LOAD_ID) of an input file for the current interface:
  --   1. the load already marked in this call (a unit may re-open a file it marked)
  --   2. the session/load id passed to BEGIN_UNIT, whatever its flag
  --   3. otherwise the oldest unprocessed load
  FUNCTION input_session(p_filename IN VARCHAR2) RETURN VARCHAR2 IS
    l_session oraas_file_in.load_id%TYPE;
    l_if      VARCHAR2(100) := current_interface;
    l_given   VARCHAR2(256) := current_session;
    l_n       NUMBER;
  BEGIN
    IF g_marked.EXISTS(l_if || '|' || p_filename) THEN
      RETURN g_marked(l_if || '|' || p_filename);
    END IF;
    IF l_given IS NOT NULL THEN
      SELECT COUNT(*)
        INTO l_n
        FROM oraas_file_in
       WHERE interface_code = l_if
         AND file_name      = p_filename
         AND load_id        = l_given
         AND ROWNUM         = 1;
      RETURN CASE WHEN l_n > 0 THEN l_given END;
    END IF;
    SELECT load_id
      INTO l_session
      FROM (SELECT load_id, MIN(loaded_at) first_loaded
              FROM oraas_file_in
             WHERE interface_code = l_if
               AND file_name      = p_filename
               AND processed_flag = 'N'
             GROUP BY load_id
             ORDER BY first_loaded, load_id)
     WHERE ROWNUM = 1;
    RETURN l_session;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN NULL;
  END input_session;

  -- 'E' when the destination folder is an error/reject folder, otherwise 'Y'.
  FUNCTION disposition_flag(p_dest_location IN VARCHAR2) RETURN VARCHAR2 IS
    l_err BOOLEAN;
  BEGIN
    BEGIN
      l_err := oraas_utl_adapter.is_error_location(p_dest_location);
    EXCEPTION
      WHEN OTHERS THEN
        l_err := FALSE;
        write_log('IS_ERROR_LOCATION failed for ' || p_dest_location || ': ' || SQLERRM);
    END;
    RETURN CASE WHEN NVL(l_err, FALSE) THEN 'E' ELSE 'Y' END;
  END disposition_flag;

  -- Sets PROCESSED_FLAG of one load of an input file, committed at once in its own
  -- transaction (a legacy file move survived ROLLBACK). Called by the converted code
  -- after FCLOSE, and by FRENAME/FCOPY+FREMOVE. The last call for a load wins, so a
  -- move to the error folder after a successful close still ends as 'E'.
  PROCEDURE mark_input(p_filename IN VARCHAR2,
                       p_session  IN VARCHAR2 DEFAULT NULL,
                       p_flag     IN VARCHAR2 DEFAULT 'Y',
                       p_how      IN VARCHAR2 DEFAULT NULL) IS
    l_if   VARCHAR2(100) := current_interface;
    l_flag VARCHAR2(10)  := UPPER(TRIM(p_flag));
    l_ses  VARCHAR2(256);
    l_n    NUMBER := 0;
    PROCEDURE do_update IS
      PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
      UPDATE oraas_file_in
         SET processed_flag = l_flag
       WHERE interface_code = l_if
         AND file_name      = p_filename
         AND load_id        = l_ses
         AND NVL(processed_flag, '?') <> l_flag;
      l_n := SQL%ROWCOUNT;
      COMMIT;
    END do_update;
  BEGIN
    IF l_flag IS NULL OR l_flag NOT IN ('Y', 'E', 'N') THEN
      write_log('MARK_INPUT: invalid flag ' || p_flag || ' for ' || l_if || '/' || p_filename);
      RAISE invalid_operation;
    END IF;
    l_ses := NVL(p_session, input_session(p_filename));
    IF p_filename IS NULL OR l_ses IS NULL THEN
      write_log('MARK_INPUT ignored, no load found for ' || l_if || '/' || p_filename ||
                ' load=' || NVL(p_session, '-') || ' by ' || p_how);
      RETURN;
    END IF;
    do_update;
    g_marked(l_if || '|' || p_filename) := l_ses;
    BEGIN
      oraas_utl_adapter.on_input_marked(l_if, p_filename, l_ses, l_flag, p_how);
    EXCEPTION
      WHEN OTHERS THEN
        write_log('ON_INPUT_MARKED failed for ' || l_if || '/' || p_filename || ': ' || SQLERRM);
    END;
    write_log('input ' || l_if || '/' || p_filename || ' load=' || l_ses ||
              ' marked ' || l_flag || ' (' || l_n || ' rows) by ' || NVL(p_how, '-'));
  END mark_input;

  FUNCTION list_input_files RETURN input_file_tab PIPELINED IS
    l_if   VARCHAR2(128) := current_interface;
    l_load VARCHAR2(256) := current_session;
    l_rec  input_file_rec;
  BEGIN
    FOR r IN (SELECT file_name,
                     SUM(NVL(LENGTHB(line_text), 0) + 1) file_size,
                     MAX(loaded_at)                      loaded_at,
                     MIN(load_id)                        load_id
                FROM oraas_file_in
               WHERE interface_code = l_if
                 AND processed_flag = 'N'
                 AND (l_load IS NULL OR load_id = l_load)
               GROUP BY file_name
               ORDER BY MIN(loaded_at), file_name) LOOP
      l_rec.file_name := r.file_name;
      l_rec.file_size := r.file_size;
      l_rec.loaded_at := r.loaded_at;
      l_rec.load_id   := r.load_id;
      PIPE ROW (l_rec);
    END LOOP;
    RETURN;
  END list_input_files;

  FUNCTION read_id(p_file IN file_type) RETURN PLS_INTEGER IS
  BEGIN
    IF p_file.id IS NOT NULL AND g_reads.EXISTS(p_file.id) THEN
      IF g_reads(p_file.id).state <> c_open THEN
        RAISE invalid_filehandle;
      END IF;
      RETURN p_file.id;
    END IF;
    IF p_file.id IS NOT NULL AND g_files.EXISTS(p_file.id) THEN
      RAISE invalid_operation;          -- file not open for reading
    END IF;
    RAISE invalid_filehandle;
  END read_id;

  FUNCTION open_read(p_location IN VARCHAR2, p_filename IN VARCHAR2,
                     p_max IN BINARY_INTEGER, p_nchar IN BOOLEAN)
  RETURN file_type IS
    l_file    file_type;
    l_session VARCHAR2(256);
    l_id      PLS_INTEGER;
  BEGIN
    l_session := input_session(p_filename);
    IF l_session IS NULL THEN
      write_log('FOPEN r: no unprocessed raw rows for ' || current_interface || '/' ||
                p_filename || ' (location ' || p_location || ')');
      RAISE invalid_operation;          -- legacy: file not found
    END IF;
    g_next_file := g_next_file + 1;
    l_id := g_next_file;
    g_reads(l_id).frame_id      := top_frame_id;
    g_reads(l_id).state         := c_open;
    g_reads(l_id).closed_by_all := FALSE;
    g_reads(l_id).location      := p_location;
    g_reads(l_id).filename      := p_filename;
    g_reads(l_id).interface     := current_interface;
    g_reads(l_id).session_id    := l_session;
    g_reads(l_id).max_linesize  := p_max;
    g_reads(l_id).last_line_no  := -1;
    g_reads(l_id).line_idx      := 1;
    g_reads(l_id).eof           := FALSE;
    g_reads(l_id).bytes_read    := 0;
    l_file.id        := l_id;
    l_file.datatype  := CASE WHEN p_nchar THEN 2 ELSE 1 END;
    l_file.byte_mode := FALSE;
    RETURN l_file;
  END open_read;

  -- Next line of an input file. Raises NO_DATA_FOUND at end of file.
  FUNCTION next_line(p_id IN PLS_INTEGER, p_len IN BINARY_INTEGER) RETURN VARCHAR2 IS
    l_line   VARCHAR2(32767);
    l_nos    DBMS_SQL.NUMBER_TABLE;
    l_data   line_tab;
  BEGIN
    IF g_reads(p_id).remainder IS NOT NULL THEN
      l_line := g_reads(p_id).remainder;
      g_reads(p_id).remainder := NULL;
    ELSE
      IF g_reads(p_id).line_idx > g_reads(p_id).lines.COUNT THEN
        IF g_reads(p_id).eof THEN
          RAISE NO_DATA_FOUND;
        END IF;
        SELECT line_no, line_text
          BULK COLLECT INTO l_nos, l_data
          FROM (SELECT line_no, line_text
                  FROM oraas_file_in
                 WHERE interface_code = g_reads(p_id).interface
                   AND file_name      = g_reads(p_id).filename
                   AND load_id        = g_reads(p_id).session_id
                   AND line_no        > g_reads(p_id).last_line_no
                 ORDER BY line_no)
         WHERE ROWNUM <= c_read_chunk;
        g_reads(p_id).lines    := l_data;
        g_reads(p_id).line_idx := 1;
        IF l_nos.COUNT > 0 THEN
          g_reads(p_id).last_line_no := l_nos(l_nos.COUNT);
        END IF;
        IF l_nos.COUNT < c_read_chunk THEN
          g_reads(p_id).eof := TRUE;
        END IF;
        IF l_nos.COUNT = 0 THEN
          RAISE NO_DATA_FOUND;
        END IF;
      END IF;
      l_line := g_reads(p_id).lines(g_reads(p_id).line_idx);
      g_reads(p_id).line_idx := g_reads(p_id).line_idx + 1;
      IF c_enforce_read_linesize AND NVL(LENGTHB(l_line), 0) > g_reads(p_id).max_linesize THEN
        RAISE read_error;
      END IF;
    END IF;
    IF p_len IS NOT NULL AND NVL(LENGTHB(l_line), 0) > p_len THEN
      g_reads(p_id).remainder := SUBSTRB(l_line, p_len + 1);
      l_line := SUBSTRB(l_line, 1, p_len);
    END IF;
    g_reads(p_id).bytes_read := g_reads(p_id).bytes_read + NVL(LENGTHB(l_line), 0) + 1;
    RETURN l_line;
  END next_line;


  -- ========================================================= UTL_FILE API
  FUNCTION open_internal(p_location IN VARCHAR2, p_filename IN VARCHAR2,
                         p_mode IN VARCHAR2, p_max IN BINARY_INTEGER,
                         p_nchar IN BOOLEAN)
  RETURN file_type IS
    l_mode     VARCHAR2(10) := LOWER(TRIM(p_mode));
    l_file     file_type;
    l_existing PLS_INTEGER;
    l_id       PLS_INTEGER;
  BEGIN
    IF p_location IS NULL THEN
      RAISE invalid_path;
    END IF;
    IF p_filename IS NULL THEN
      RAISE invalid_filename;
    END IF;
    IF p_max IS NULL OR p_max < 1 OR p_max > 32767 THEN
      RAISE invalid_maxlinesize;
    END IF;
    IF l_mode IN ('rb', 'wb', 'ab') THEN
      write_log('FOPEN byte mode ' || p_mode || ' is not supported by the shim: ' ||
          p_location || '/' || p_filename);
      RAISE invalid_operation;
    END IF;
    IF l_mode = 'r' THEN
      RETURN open_read(p_location, p_filename, p_max, p_nchar);
    END IF;
    IF l_mode IS NULL OR l_mode NOT IN ('w', 'a') THEN
      RAISE invalid_mode;
    END IF;
    l_id := top_frame_id;    -- raises if no converted unit is active

    l_existing := find_file(p_location, p_filename);
    IF l_existing IS NOT NULL AND g_files(l_existing).state = c_open THEN
      write_log('FOPEN of a file that is already open in this session: ' ||
          p_location || '/' || p_filename);
      RAISE invalid_operation;
    END IF;

    IF l_mode = 'a' AND l_existing IS NOT NULL THEN
      -- append to a file closed earlier in this session: reuse its buffer
      g_files(l_existing).state         := c_open;
      g_files(l_existing).closed_by_all := FALSE;
      g_files(l_existing).close_seq     := NULL;
      g_files(l_existing).frame_id      := top_frame_id;
      l_id := l_existing;
    ELSE
      IF l_existing IS NOT NULL THEN
        drop_file(l_existing);  -- 'w' truncates: the earlier pending file is superseded
      END IF;
      IF l_mode = 'a' THEN
        write_log('FOPEN mode a: no earlier content of ' || p_location || '/' || p_filename ||
            ' exists in this session; the file starts empty');
      END IF;
      l_id := new_file(p_location, p_filename, l_mode, c_open);
    END IF;

    l_file.id        := l_id;
    l_file.datatype  := CASE WHEN p_nchar THEN 2 ELSE 1 END;
    l_file.byte_mode := FALSE;
    RETURN l_file;
  END open_internal;

  FUNCTION fopen(location IN VARCHAR2, filename IN VARCHAR2, open_mode IN VARCHAR2,
                 max_linesize IN BINARY_INTEGER DEFAULT 1024)
  RETURN file_type IS
  BEGIN
    RETURN open_internal(location, filename, open_mode, max_linesize, FALSE);
  END fopen;

  FUNCTION fopen_nchar(location IN VARCHAR2, filename IN VARCHAR2, open_mode IN VARCHAR2,
                       max_linesize IN BINARY_INTEGER DEFAULT 1024)
  RETURN file_type IS
  BEGIN
    RETURN open_internal(location, filename, open_mode, max_linesize, TRUE);
  END fopen_nchar;

  -- After FCLOSE_ALL, IS_OPEN still returns TRUE (documented UTL_FILE behaviour).
  FUNCTION is_open(file IN file_type) RETURN BOOLEAN IS
  BEGIN
    IF file.id IS NOT NULL AND g_reads.EXISTS(file.id) THEN
      RETURN g_reads(file.id).state = c_open
             OR NVL(g_reads(file.id).closed_by_all, FALSE);
    END IF;
    IF file.id IS NULL OR NOT g_files.EXISTS(file.id) THEN
      RETURN FALSE;
    END IF;
    RETURN g_files(file.id).state IN (c_open, c_ropen)
           OR (g_files(file.id).state = c_closed AND NVL(g_files(file.id).closed_by_all, FALSE));
  END is_open;

  PROCEDURE fclose(file IN OUT file_type) IS
    l_id PLS_INTEGER;
  BEGIN
    IF file.id IS NOT NULL AND g_reads.EXISTS(file.id) THEN
      IF g_reads(file.id).state <> c_open AND NOT NVL(g_reads(file.id).closed_by_all, FALSE) THEN
        RAISE invalid_filehandle;
      END IF;
      g_reads(file.id).state := c_closed;
      g_reads(file.id).lines.DELETE;
      file.id := NULL;
      RETURN;
    END IF;
    l_id := handle_id(file);
    IF g_files(l_id).state = c_closed AND NVL(g_files(l_id).closed_by_all, FALSE) THEN
      file.id := NULL;       -- already closed by FCLOSE_ALL
      RETURN;
    END IF;
    IF g_files(l_id).state NOT IN (c_open, c_ropen) THEN
      RAISE invalid_filehandle;
    END IF;
    flush_stage(l_id);
    IF g_files(l_id).state = c_ropen THEN
      free_buf(l_id);
      g_files(l_id).state := c_removed;
    ELSE
      g_files(l_id).state := c_closed;
      g_close_seq := g_close_seq + 1;
      g_files(l_id).close_seq := g_close_seq;
    END IF;
    file.id := NULL;
  END fclose;

  PROCEDURE fclose_all IS
    l_id PLS_INTEGER;
  BEGIN
    l_id := g_files.FIRST;
    WHILE l_id IS NOT NULL LOOP
      IF g_files(l_id).state = c_open THEN
        flush_stage(l_id);
        g_files(l_id).state := c_closed;
        g_files(l_id).closed_by_all := TRUE;
        g_close_seq := g_close_seq + 1;
        g_files(l_id).close_seq := g_close_seq;
      ELSIF g_files(l_id).state = c_ropen THEN
        free_buf(l_id);
        g_files(l_id).state := c_removed;
      END IF;
      l_id := g_files.NEXT(l_id);
    END LOOP;
    l_id := g_reads.FIRST;
    WHILE l_id IS NOT NULL LOOP
      IF g_reads(l_id).state = c_open THEN
        g_reads(l_id).state := c_closed;
        g_reads(l_id).closed_by_all := TRUE;
        g_reads(l_id).lines.DELETE;
      END IF;
      l_id := g_reads.NEXT(l_id);
    END LOOP;
  END fclose_all;

  PROCEDURE fflush(file IN file_type) IS
    l_id PLS_INTEGER := writable_id(file);
  BEGIN
    NULL;                    -- buffered until END_UNIT; nothing to flush
  END fflush;

  PROCEDURE put(file IN file_type, buffer IN VARCHAR2) IS
  BEGIN
    append_text(writable_id(file), buffer);
  END put;

  PROCEDURE put_line(file IN file_type, buffer IN VARCHAR2, autoflush IN BOOLEAN DEFAULT FALSE) IS
    l_id PLS_INTEGER := writable_id(file);
  BEGIN
    append_text(l_id, buffer);
    append_text(l_id, c_terminator);
  END put_line;

  PROCEDURE new_line(file IN file_type, lines IN NATURAL := 1) IS
    l_id PLS_INTEGER := writable_id(file);
  BEGIN
    FOR i IN 1 .. NVL(lines, 1) LOOP
      append_text(l_id, c_terminator);
    END LOOP;
  END new_line;

  PROCEDURE putf(file IN file_type, format IN VARCHAR2,
                 arg1 IN VARCHAR2 DEFAULT NULL, arg2 IN VARCHAR2 DEFAULT NULL,
                 arg3 IN VARCHAR2 DEFAULT NULL, arg4 IN VARCHAR2 DEFAULT NULL,
                 arg5 IN VARCHAR2 DEFAULT NULL) IS
    l_id   PLS_INTEGER := writable_id(file);
    l_len  PLS_INTEGER := NVL(LENGTH(format), 0);
    l_pos  PLS_INTEGER := 1;
    l_arg  PLS_INTEGER := 0;
    l_p1   PLS_INTEGER;
    l_p2   PLS_INTEGER;
    l_nx   PLS_INTEGER;
  BEGIN
    WHILE l_pos <= l_len LOOP
      IF SUBSTR(format, l_pos, 2) = '%s' THEN
        l_arg := l_arg + 1;
        append_text(l_id, CASE l_arg WHEN 1 THEN arg1 WHEN 2 THEN arg2 WHEN 3 THEN arg3
                                     WHEN 4 THEN arg4 WHEN 5 THEN arg5 END);
        l_pos := l_pos + 2;
      ELSIF SUBSTR(format, l_pos, 2) = '\n' THEN
        append_text(l_id, c_terminator);
        l_pos := l_pos + 2;
      ELSE
        l_p1 := INSTR(format, '%', l_pos + 1);
        l_p2 := INSTR(format, '\', l_pos + 1);
        l_nx := LEAST(CASE WHEN l_p1 = 0 THEN l_len + 1 ELSE l_p1 END,
                      CASE WHEN l_p2 = 0 THEN l_len + 1 ELSE l_p2 END);
        append_text(l_id, SUBSTR(format, l_pos, l_nx - l_pos));
        l_pos := l_nx;
      END IF;
    END LOOP;
  END putf;

  PROCEDURE put_nchar(file IN file_type, buffer IN NVARCHAR2) IS
  BEGIN
    append_nchar(writable_id(file), buffer);
  END put_nchar;

  PROCEDURE put_line_nchar(file IN file_type, buffer IN NVARCHAR2) IS
    l_id PLS_INTEGER := writable_id(file);
  BEGIN
    append_nchar(l_id, buffer);
    append_text(l_id, c_terminator);
  END put_line_nchar;

  PROCEDURE putf_nchar(file IN file_type, format IN NVARCHAR2,
                       arg1 IN NVARCHAR2 DEFAULT NULL, arg2 IN NVARCHAR2 DEFAULT NULL,
                       arg3 IN NVARCHAR2 DEFAULT NULL, arg4 IN NVARCHAR2 DEFAULT NULL,
                       arg5 IN NVARCHAR2 DEFAULT NULL) IS
    l_id   PLS_INTEGER := writable_id(file);
    l_len  PLS_INTEGER := NVL(LENGTH(format), 0);
    l_pos  PLS_INTEGER := 1;
    l_arg  PLS_INTEGER := 0;
    l_p1   PLS_INTEGER;
    l_p2   PLS_INTEGER;
    l_nx   PLS_INTEGER;
  BEGIN
    WHILE l_pos <= l_len LOOP
      IF SUBSTR(format, l_pos, 2) = N'%s' THEN
        l_arg := l_arg + 1;
        append_nchar(l_id, CASE l_arg WHEN 1 THEN arg1 WHEN 2 THEN arg2 WHEN 3 THEN arg3
                                      WHEN 4 THEN arg4 WHEN 5 THEN arg5 END);
        l_pos := l_pos + 2;
      ELSIF SUBSTR(format, l_pos, 2) = N'\n' THEN
        append_text(l_id, c_terminator);
        l_pos := l_pos + 2;
      ELSE
        l_p1 := INSTR(format, N'%', l_pos + 1);
        l_p2 := INSTR(format, N'\', l_pos + 1);
        l_nx := LEAST(CASE WHEN l_p1 = 0 THEN l_len + 1 ELSE l_p1 END,
                      CASE WHEN l_p2 = 0 THEN l_len + 1 ELSE l_p2 END);
        append_nchar(l_id, SUBSTR(format, l_pos, l_nx - l_pos));
        l_pos := l_nx;
      END IF;
    END LOOP;
  END putf_nchar;

  PROCEDURE get_line(file IN file_type, buffer OUT VARCHAR2, len IN BINARY_INTEGER DEFAULT NULL) IS
    l_id PLS_INTEGER := read_id(file);
  BEGIN
    buffer := next_line(l_id, len);     -- VALUE_ERROR if the line does not fit, as legacy
  END get_line;

  PROCEDURE get_line_nchar(file IN file_type, buffer OUT NVARCHAR2, len IN BINARY_INTEGER DEFAULT NULL) IS
    l_id PLS_INTEGER := read_id(file);
  BEGIN
    buffer := TO_NCHAR(next_line(l_id, len));
  END get_line_nchar;

  PROCEDURE fremove(location IN VARCHAR2, filename IN VARCHAR2) IS
    l_id      PLS_INTEGER := find_file(location, filename);
    l_session VARCHAR2(256);
    l_key     VARCHAR2(500);
  BEGIN
    IF l_id IS NULL THEN
      l_session := CASE WHEN g_top > 0 THEN input_session(filename) END;
      IF l_session IS NOT NULL THEN
        l_key := current_interface || '|' || filename;
        mark_input(filename, l_session,
                   CASE WHEN g_pending.EXISTS(l_key) THEN g_pending(l_key) ELSE 'Y' END,
                   'FREMOVE' || CASE WHEN g_pending.EXISTS(l_key) THEN ' after FCOPY' ELSE ' (no prior FCOPY)' END);
        IF g_pending.EXISTS(l_key) THEN
          g_pending.DELETE(l_key);
        END IF;
        RETURN;
      END IF;
      write_log('FREMOVE ignored, file not produced in this session: ' || location || '/' || filename);
      RETURN;
    END IF;
    IF g_files(l_id).state = c_open THEN
      g_files(l_id).state := c_ropen;   -- legacy: unlink while open, nothing remains after close
    ELSE
      free_buf(l_id);
      g_files(l_id).state := c_removed;
    END IF;
  END fremove;

  PROCEDURE frename(src_location IN VARCHAR2, src_filename IN VARCHAR2,
                    dest_location IN VARCHAR2, dest_filename IN VARCHAR2,
                    overwrite IN BOOLEAN DEFAULT FALSE) IS
    l_src     PLS_INTEGER := find_file(src_location, src_filename);
    l_dst     PLS_INTEGER;
    l_session VARCHAR2(256);
  BEGIN
    IF l_src IS NULL THEN
      l_session := CASE WHEN g_top > 0 THEN input_session(src_filename) END;
      IF l_session IS NOT NULL THEN
        mark_input(src_filename, l_session, disposition_flag(dest_location),
                   'FRENAME to ' || dest_location);
        RETURN;
      END IF;
      write_log('FRENAME ignored, file not produced in this session: ' ||
          src_location || '/' || src_filename);
      RETURN;
    END IF;
    l_dst := find_file(dest_location, dest_filename);
    IF l_dst IS NOT NULL AND l_dst <> l_src THEN
      IF NOT NVL(overwrite, FALSE) THEN
        RAISE rename_failed;
      END IF;
      IF g_files(l_dst).state = c_open THEN
        g_files(l_dst).state := c_ropen;
      ELSE
        free_buf(l_dst);
        g_files(l_dst).state := c_removed;
      END IF;
    END IF;
    g_files(l_src).location := dest_location;
    g_files(l_src).filename := dest_filename;
  END frename;

  PROCEDURE fcopy(src_location IN VARCHAR2, src_filename IN VARCHAR2,
                  dest_location IN VARCHAR2, dest_filename IN VARCHAR2,
                  start_line IN BINARY_INTEGER DEFAULT 1,
                  end_line IN BINARY_INTEGER DEFAULT NULL) IS
    c_chunk CONSTANT PLS_INTEGER := 8000;
    l_src   PLS_INTEGER := find_file(src_location, src_filename);
    l_dst   PLS_INTEGER;
    l_old   PLS_INTEGER;
    l_total NUMBER;
    l_pos   NUMBER := 1;
    l_end   NUMBER;
    l_nl    NUMBER;
    l_line  PLS_INTEGER := 1;
    l_off   NUMBER;
  BEGIN
    IF l_src IS NULL THEN
      IF g_top > 0 AND input_session(src_filename) IS NOT NULL THEN
        -- copy of an input file to an archive folder: the FREMOVE that follows marks it
        g_pending(current_interface || '|' || src_filename) := disposition_flag(dest_location);
        write_log('FCOPY of input ' || src_filename || ' to ' || dest_location ||
                  ' recorded; applied at FREMOVE');
        RETURN;
      END IF;
      write_log('FCOPY ignored, source not produced in this session: ' ||
          src_location || '/' || src_filename);
      RETURN;
    END IF;
    IF NVL(start_line, 1) < 1 OR (end_line IS NOT NULL AND end_line < NVL(start_line, 1)) THEN
      RAISE invalid_offset;
    END IF;
    flush_stage(l_src);
    l_old := find_file(dest_location, dest_filename);
    IF l_old IS NOT NULL AND l_old <> l_src THEN
      drop_file(l_old);       -- copy overwrites the destination
    END IF;
    l_dst := new_file(dest_location, dest_filename, 'w', c_closed);
    l_total := DBMS_LOB.GETLENGTH(g_files(l_src).buf);
    WHILE l_pos <= l_total LOOP
      l_nl  := DBMS_LOB.INSTR(g_files(l_src).buf, c_terminator, l_pos);
      l_end := CASE WHEN l_nl = 0 THEN l_total ELSE l_nl + LENGTH(c_terminator) - 1 END;
      IF l_line >= NVL(start_line, 1) THEN
        l_off := l_pos;
        WHILE l_off <= l_end LOOP
          append_text(l_dst, DBMS_LOB.SUBSTR(g_files(l_src).buf,
                                             LEAST(c_chunk, l_end - l_off + 1), l_off));
          l_off := l_off + c_chunk;
        END LOOP;
      END IF;
      EXIT WHEN end_line IS NOT NULL AND l_line >= end_line;
      l_pos  := l_end + 1;
      l_line := l_line + 1;
    END LOOP;
    flush_stage(l_dst);
  END fcopy;

  PROCEDURE fgetattr(location IN VARCHAR2, filename IN VARCHAR2,
                     fexists OUT BOOLEAN, file_length OUT NUMBER,
                     block_size OUT BINARY_INTEGER) IS
    l_id      PLS_INTEGER := find_file(location, filename);
    l_session VARCHAR2(256);
    l_if      VARCHAR2(100);
  BEGIN
    IF l_id IS NULL AND g_top > 0 THEN
      l_session := input_session(filename);
      IF l_session IS NOT NULL THEN
        l_if := current_interface;
        SELECT SUM(NVL(LENGTHB(line_text), 0) + 1)
          INTO file_length
          FROM oraas_file_in
         WHERE interface_code = l_if
           AND file_name      = filename
           AND load_id        = l_session;
        fexists := TRUE;
        block_size := NULL;
        RETURN;
      END IF;
    END IF;
    IF l_id IS NULL THEN
      write_log('FGETATTR: file not produced in this session, reported as not existing: ' ||
          location || '/' || filename);
      fexists := FALSE;
      file_length := NULL;
      block_size := NULL;
    ELSE
      fexists := TRUE;
      file_length := g_files(l_id).bytes;
      block_size := NULL;
    END IF;
  END fgetattr;

  FUNCTION fgetpos(file IN file_type) RETURN PLS_INTEGER IS
  BEGIN
    IF file.id IS NOT NULL AND g_reads.EXISTS(file.id) THEN
      RETURN g_reads(file.id).bytes_read;
    END IF;
    RETURN g_files(handle_id(file)).bytes;
  END fgetpos;

END oraas_utl;
/
SHOW ERRORS
