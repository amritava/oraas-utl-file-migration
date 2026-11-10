# Writing your site adapter

The shim never knows your table or procedure names. Everything site-specific is in one package
body, `ORAAS_UTL_ADAPTER`, plus (optionally) a view and a listing procedure. Keep all three in
your own private repository.

## 1. Answer these questions first

| Question | Where it goes |
|---|---|
| How must a finished output file leave the database? (existing hand-off procedure, object storage, REST call, a poller reading ORAAS_FILE_OUT) | `on_file_ready` |
| Must the unit wait until the file is delivered? | `on_file_ready` (synchronous) or a poller (asynchronous) |
| Where are incoming file lines stored? (new ORAAS_FILE_IN, or an existing table) | table or view `ORAAS_FILE_IN` |
| What identifies one load of one file? | `LOAD_ID`, passed by the caller as the session parameter |
| How is the physical input file archived after Y/E? | `on_input_marked` |
| Which destinations are error folders? | `is_error_location` |
| Where should diagnostics go? | `log` |
| Do legacy units call a directory-listing procedure? | listing replacement + `frame_trigger_calls` |
| Character set of the database; OS of the legacy database server (LF or CRLF) | check `c_terminator` in `04_oraas_utl.pkb` |

## 2. Output: `on_file_ready(p_file_id)`

The row is already committed when this is called. Read it and deliver:

```sql
PROCEDURE on_file_ready(p_file_id IN NUMBER) IS
  r oraas_file_out%ROWTYPE;
BEGIN
  SELECT * INTO r FROM oraas_file_out WHERE file_id = p_file_id;
  -- call YOUR delivery here, for example an existing hand-off procedure:
  -- my_handoff_proc(p_path => r.location, p_name => r.file_name, p_data => r.content,
  --                 p_empty => r.is_empty, p_batch => r.run_id, po_status => l_status);
  -- IF l_status <> 0 THEN RAISE_APPLICATION_ERROR(-20999, 'delivery failed'); END IF;
  UPDATE oraas_file_out SET status = 'SENT' WHERE file_id = p_file_id;  -- in an autonomous helper
END;
```

Raise to report failure; the shim marks the row FAILED and raises ORA-20901 in the unit.
`object_storage_adapter.pkb` is a complete example using `DBMS_CLOUD.PUT_OBJECT`.

Byte parity: the content is the exact text the legacy unit wrote. The delivering side must write
it as UTF-8 (or the legacy file encoding) without adding a BOM or a final line feed.

## 3. Input: `ORAAS_FILE_IN`

Either let your loader insert into the table from `01_oraas_file_tables.sql`, or drop that table
and create an updatable view over your existing one:

```sql
CREATE OR REPLACE VIEW oraas_file_in AS
SELECT my_interface_col AS interface_code, my_file_col AS file_name, my_load_col AS load_id,
       my_line_no_col AS line_no, my_text_col AS line_text, my_loaded_col AS loaded_at,
       my_flag_col AS processed_flag
  FROM my_raw_upload_table;
```

Loader contract: one row per line, `LINE_NO` from 1 in file order, line text without the line
terminator (strip CR from CRLF files), `INTERFACE_CODE` = converted unit name in capitals (or the
value in `interface_overrides`), `PROCESSED_FLAG = 'N'`, one `LOAD_ID` per load of one file. Decide
whether blank lines and empty files are stored: legacy code that checks for them only works if
they are.

## 4. Input marks: `on_input_marked`

Called after `PROCESSED_FLAG` changes (already committed). Typical use: tell the loader to move
the physical file to a done or error folder, or `DBMS_CLOUD.MOVE_OBJECT` between prefixes.

## 5. `is_error_location`

Return TRUE for destinations that mean "error/reject". The default checks for the words ERR,
ERROR, REJECT, FAIL (whole words) in the destination. If your folders are held in a parameter
table, look the name up there.

## 6. Legacy directory listing

If units call a procedure that lists an OS folder into a table, replace that procedure once with
`plsql/adapters/listing_procedure_template.sql` (renamed to your names) and list its name under
`frame_trigger_calls` in your copy of `upload_rules.json`.

## 7. Install order

```
01_oraas_file_tables.sql        (or your view for ORAAS_FILE_IN)
02_oraas_utl_adapter.pks
<your adapter body>.pkb
03_oraas_utl.pks
04_oraas_utl.pkb
<your listing replacement>      (optional)
```
