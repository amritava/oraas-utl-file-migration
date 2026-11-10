# Decisions and their alternatives

Each decision changes generated code. Change it in the recipe or the shim, rerun the batch, and
record the change in CHANGELOG.md. Never change it in a single converted unit.

| # | Decision | Alternative | Where to change |
|---|---|---|---|
| D1 | Replace the file layer (shim), do not rewrite file logic | Rule-based rewriting into cursors: rejected, it changes end-of-file, handler and byte behaviour | — |
| D2 | Written files are released when the unit ends, not at FCLOSE | Release at FCLOSE: needs remove/rename support on the delivery side | `04_oraas_utl.pkb` |
| D3 | Release only on success (status parameter, no escaping exception) | Release whatever legacy left on disk, including partial files | `status` in download rules |
| D4 | Open files at exit are discarded, except in units that never call FCLOSE | Always submit / always discard | `open_handles_at_end` |
| D5 | Empty files are stored with IS_EMPTY = Y and NULL content | Skip empty files | `submit_file` in the body |
| D6 | One RUN_ID per outermost converted call | One per unit | body |
| D7 | Legacy bytes are the reference; LF terminator | CRLF for files from a Windows legacy server | `c_terminator` |
| D8 | Input marks committed immediately; last mark wins | Commit with the business transaction | `mark_input` |
| D9 | Failed reads mark N (re-read next run) | E (never re-read without manual reset) | `mark_on_close.failure_flag` |
| D10 | Interface code = unit name in capitals | Explicit mapping | `interface_overrides` |
| D11 | Session/load id becomes an IN parameter replacing USERENV('SESSIONID') | Keep the database session id; read the oldest unprocessed load | `session` (set null to disable) |
| D12 | No business-date filter when choosing input files | Filter by date | `input_session` in the body |
| D13 | Byte mode, directory objects, package-level handles are refused | Hand migration | `members`, `directory_dependencies` |
