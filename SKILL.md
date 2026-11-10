---
name: oraas-utl-file-migration
description: Migrate Oracle PL/SQL that uses UTL_FILE (writing or reading server files) to Oracle Autonomous Database / ORAAS, where UTL_FILE and directory objects are unavailable. Use for batch conversion of procedures, functions and package bodies that call UTL_FILE.FOPEN, PUT_LINE, GET_LINE, FCLOSE, FRENAME or FREMOVE, by installing a UTL_FILE-compatible shim and renaming calls instead of rewriting business logic.
---

# ORAAS UTL_FILE migration

## The approach (do not deviate)

Never rewrite file-handling business logic unit by unit. Instead:

1. Install the **ORAAS_UTL** shim (`plsql/`). It has the same procedures, parameter names and
   exception codes as UTL_FILE, but keeps files in tables:
   written files go to `ORAAS_FILE_OUT`, input files are read from `ORAAS_FILE_IN`.
2. Connect the site's integration through **ORAAS_UTL_ADAPTER** (one small package body the site
   owns; `references/adapter-guide.md`). The skill never contains site table or procedure names.
3. Convert units mechanically with `scripts/oraas_convert.py`: rename `UTL_FILE` to `ORAAS_UTL`,
   add `BEGIN_UNIT` / `END_UNIT` frame calls, and for uploads add a load-id parameter and
   `MARK_INPUT` after each input `FCLOSE`.

Read `references/design.md` before changing any behaviour.

## Workflow

1. **Inventory.** Ask the user for the legacy sources exported from the database as plain text
   (never Word files or old repository copies). Put download units (write files) and upload units
   (read files) in separate folders. A unit that does both goes with uploads.
2. **Site settings.** Copy `config/download_rules.json` and `config/upload_rules.json` to the
   user's private workspace and fill in, with the user:
   - status OUT parameter names (`status.code_aliases`);
   - names of a legacy directory-listing procedure, if any (`frame_trigger_calls`);
   - objects that mark a unit as already hand-migrated (`manual_markers`, `shared_objects`);
   - business-date and context parameters (`metadata`); session parameter (`session`);
   - failure flag after a failed read (`mark_on_close.failure_flag`: N re-reads, E does not).
   Site names go ONLY into these private copies, never into the skill folder.
3. **Adapter.** Help the user write their `ORAAS_UTL_ADAPTER` body from
   `plsql/adapters/default_adapter.pkb` (how files leave, how inputs arrive, which folders are
   error folders). Keep it in the user's repository.
4. **Convert.**
   `python scripts/oraas_convert.py --direction download --rules <their download rules> <folder>`
   `python scripts/oraas_convert.py --direction upload   --rules <their upload rules>   <folder>`
5. **Review.** Read the batch summary CSV. For each REVIEW_REQUIRED unit give the code, line and
   fix from `references/codes.md`. Explain every warning. Never hand-edit generated output to
   silence a refusal; fix the source or the rules and rerun with `--overwrite`.
6. **Verify before calling anything migrated.** Compile on the target database; run
   `tests/oraas_utl_unit_tests.sql` then `tests/oraas_utl_upload_tests.sql` in a scratch schema;
   byte-compare download files with `scripts/oraas_golden_compare.py`; parallel-run uploads.
   Until then, label output "generated, unverified".

## Fixed rules (change only when the user decides, and record it)

- A unit's written files are released only if its status parameter says success at exit and no
  exception escaped. Files still open at exit are discarded, except in units that never call
  FCLOSE (legacy closed those at session end).
- Legacy output bytes are the reference: PUT_LINE adds one LF (change `c_terminator` only if the
  legacy server was Windows), FCLOSE adds nothing, NCHAR text is stored without loss.
- Input marks are committed immediately in their own transaction; the last mark for a load wins
  (a move to an error folder after a successful close ends as E).
- Byte mode (rb/wb/ab, GET_RAW, PUT_RAW, FSEEK), directory-object calls (BFILENAME, DBMS_LOB file
  calls, external tables) and package-level file handles are refused, not converted.

## Files

| Path | Purpose |
|---|---|
| `plsql/01..04_*` | Tables, adapter specification, ORAAS_UTL spec and body |
| `plsql/adapters/` | Default adapter, object-storage example, listing-procedure template |
| `scripts/oraas_convert.py` | Batch converter (standard-library Python 3.8+) |
| `scripts/oraas_golden_compare.py` | Byte comparison of legacy and new files |
| `scripts/leak_check.py` | Blocks publishing when private names appear |
| `config/*_rules.json` | Generic recipes; copy and fill per site |
| `examples/` | Invented legacy units and their expected conversion |
| `tests/` | Converter tests (Python) and shim tests (SQL, scratch schema only) |
| `references/` | design, codes, adapter guide, decisions, publishing |
