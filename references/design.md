# Design

## 1. Problem

Legacy PL/SQL writes and reads server files with `UTL_FILE` through Oracle directory objects.
Oracle Autonomous Database (ORAAS) has no server file system for this, so every such unit fails.
Rewriting hundreds of units by hand, or with rules that rewrite file loops into cursors, changes
behaviour in ways that are hard to see: output bytes, end-of-file handling, error handlers,
which files are kept after an error.

## 2. Approach: replace the layer, not the logic

```
legacy unit ──UTL_FILE calls──► ORAAS_UTL (same API and error codes)
                                  ├─ written files  ──► ORAAS_FILE_OUT ──► adapter.on_file_ready
                                  ├─ input lines    ◄── ORAAS_FILE_IN  ◄── site loader
                                  └─ hooks          ──► ORAAS_UTL_ADAPTER (site-owned body)
```

The converter only renames `UTL_FILE` to `ORAAS_UTL` and adds a few calls. Wrappers, loops,
`GOTO` exit labels and `WHEN UTL_FILE.WRITE_ERROR` handlers keep working because the shim raises
the same error codes (ORA-29280 to ORA-29298).

## 3. Frames

Every converted unit that opens, copies or lists files gets:

```sql
l_oraas_frame PLS_INTEGER;                               -- declaration
l_oraas_frame := oraas_utl.begin_unit(p_unit_name => 'UNIT', ...);   -- first statement
oraas_utl.end_unit(l_oraas_frame, <success test>);       -- before every exit
```

`END_UNIT` is placed before the main `EXCEPTION`/`END`, before every `RETURN`, at the end of every
main handler, before every `RAISE` in a main handler (with `FALSE`), and in an added
`WHEN OTHERS THEN end_unit(FALSE); RAISE;` when the main block has none. Frames are a stack per
database session, so nested converted units do not interfere. A frame left behind by an error
inside an exception handler is detected with `UTL_CALL_STACK` at the next `BEGIN_UNIT` and
discarded; its files are never released.

## 4. Writing (download side)

Byte rules, identical to UTL_FILE text mode on a Unix host:

| Call | Bytes |
|---|---|
| `PUT(f, s)` | `s` |
| `PUT_LINE(f, s)` | `s` + LF |
| `NEW_LINE(f, n)` | n x LF |
| `PUTF(f, fmt, a1..a5)` | `%s` replaced by arguments (missing = empty), `\n` = LF |
| `FCLOSE(f)` | nothing |
| `*_NCHAR` variants | same rules, converted without loss on an AL32UTF8 database |

Release rules at `END_UNIT`:

| File state | success | failure / exception |
|---|---|---|
| Closed (FCLOSE / FCLOSE_ALL) | stored and delivered | discarded |
| Removed (FREMOVE) | discarded | discarded |
| Open, unit calls FCLOSE somewhere | discarded, logged | discarded |
| Open, unit never calls FCLOSE | stored and delivered | discarded |
| Opened and closed, nothing written | stored with `IS_EMPTY = 'Y'`, `CONTENT` NULL | discarded |

"Success" is the unit's status OUT parameter (`PO_ERR_CODE IS NULL OR PO_ERR_CODE = 0`, or `'0'`
for a text status). A unit without a status parameter always succeeds unless an exception escapes.
This is a deliberate change from UTL_FILE, which left partial files on disk after errors.

Delivery: each file is inserted into `ORAAS_FILE_OUT` in its own committed transaction (a written
file survived a ROLLBACK in legacy), then `ORAAS_UTL_ADAPTER.ON_FILE_READY(file_id)` is called.
If the adapter raises, the row is marked `FAILED` and the unit gets ORA-20901
(`ORAAS_UTL.HANDOFF_FAILED`). Files are delivered in FCLOSE order. Nested units share one
`RUN_ID`.

`FREMOVE`, `FRENAME`, `FCOPY`, `FGETATTR` act only on files produced in the current session.
Housekeeping of files from earlier runs (archiving, cleanup) is logged and ignored: move it to
the integration side.

## 5. Reading (upload side)

| Situation | UTL_FILE | ORAAS_UTL |
|---|---|---|
| File not found | INVALID_OPERATION (-29283) at FOPEN | no rows in ORAAS_FILE_IN: same |
| End of file | NO_DATA_FOUND from GET_LINE | same |
| Line longer than the buffer variable | VALUE_ERROR | same |
| Line longer than FOPEN max_linesize | READ_ERROR (-29284) | same (constant `c_enforce_read_linesize`) |
| GET_LINE on a write handle | INVALID_OPERATION | same |
| IS_OPEN after FCLOSE_ALL | TRUE (documented) | same |

Which load is read: `ORAAS_FILE_IN` rows with `INTERFACE_CODE` = unit name in capitals (or an
override), `FILE_NAME`, and `LOAD_ID` = the session/load id passed to `BEGIN_UNIT`; without one,
the oldest unprocessed load. Lines come in `LINE_NO` order, 1,000 per database call.
`LIST_INPUT_FILES` (pipelined) lists unprocessed files of the current unit; use it to replace a
legacy directory-listing procedure (`plsql/adapters/listing_procedure_template.sql`).

Marking input files (`PROCESSED_FLAG`), each committed immediately and reported to
`ADAPTER.ON_INPUT_MARKED`:

| Legacy code does | Mark |
|---|---|
| `MARK_INPUT` generated after FCLOSE in normal flow / end-of-file handler | Y if status and error flag say success, else the failure flag |
| `MARK_INPUT` generated after FCLOSE in another exception handler | failure flag (default N) |
| `FRENAME(inbox, f, dest)` | E if `ADAPTER.IS_ERROR_LOCATION(dest)`, else Y |
| `FCOPY(inbox, f, dest)` then `FREMOVE(inbox, f)` | same, applied at FREMOVE |
| `FREMOVE(inbox, f)` alone | Y |

The last mark wins. With failure flag N, a file that failed and was never moved is read again
on the next run, which is what happened when it stayed in the legacy inbox. Use E to stop rereads.

## 6. Upload-only source changes

- Session/load id: `pi_session_id IN NUMBER DEFAULT NULL` is added (name and type configurable)
  unless present. `SELECT USERENV('SESSIONID') INTO v FROM DUAL;` is commented out and replaced by
  `v := pi_session_id;`; other uses of `USERENV('SESSIONID')` are replaced and flagged. Callers
  must pass the load id; units that tag staging rows with it find nothing when it is NULL.
- `MARK_INPUT` after every FCLOSE of a handle opened in read mode, using the file-name expression
  of its FOPEN. Skipped with a warning when that expression is not visible at the FCLOSE.
- Package subprograms that need the new parameter are refused: the specification changes too.

## 7. What is refused

Byte mode and positioned reads, directory-object calls, file handles at package level or in a
package specification, handles returned or passed OUT by a unit that opens files, FOPEN in a
declaration, conditional compilation, units already migrated by hand that still use UTL_FILE,
non-text inputs. See `codes.md`.

## 8. Verification

1. Compile on the target database.
2. `tests/oraas_utl_unit_tests.sql`, then `tests/oraas_utl_upload_tests.sql`, in a scratch schema.
3. Downloads: run legacy and converted units on the same data; compare with
   `scripts/oraas_golden_compare.py` (mask only run-dependent values such as timestamps).
4. Uploads: load the same input files, compare business tables, rejects, status codes and the
   final `PROCESSED_FLAG` against the folder each legacy file ended in; include one bad file.
