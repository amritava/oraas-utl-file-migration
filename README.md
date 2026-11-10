# oraas-utl-file-migration
“Not affiliated with Oracle or any employer. Test in a non-production environment.”
Migrate Oracle PL/SQL that uses **UTL_FILE** to **Oracle Autonomous Database (ORAAS)**, where
UTL_FILE and directory objects are not available, without rewriting business logic.

- **ORAAS_UTL**: a drop-in package with the same API and error codes as UTL_FILE. Written files go
  to a table (`ORAAS_FILE_OUT`), input files are read from a table (`ORAAS_FILE_IN`).
- **ORAAS_UTL_ADAPTER**: one small package body you write to connect your own delivery and loading
  (examples: default, OCI Object Storage).
- **oraas_convert.py**: batch converter. Renames `UTL_FILE` to `ORAAS_UTL`, adds frame calls, and
  for uploads adds a load-id parameter and input marking. Units it cannot convert safely are
  refused with a reason and line number.

Works as a Claude skill (`SKILL.md`) and as a plain toolkit.

## Quick start

```bash
# 1. Database (scratch schema first), in this order
plsql/01_oraas_file_tables.sql
plsql/02_oraas_utl_adapter.pks
plsql/adapters/default_adapter.pkb      # or your own adapter body
plsql/03_oraas_utl.pks
plsql/04_oraas_utl.pkb

# 2. Try the converter on the invented examples
python scripts/oraas_convert.py --direction download examples/download
python scripts/oraas_convert.py --direction upload --rules examples/upload_rules.example.json examples/upload

# 3. Your code: copy config/*.json to a private folder, fill in your names, then
python scripts/oraas_convert.py --direction download --rules my/download_rules.json InputForDownload
python scripts/oraas_convert.py --direction upload   --rules my/upload_rules.json   InputForUpload
```

Results: converted sources (`NAME_MIG.prc`), one diff and one JSON report per file, and a batch
summary CSV, in folders next to the input folder.

## Tests

```bash
python tests/test_download_converter.py
python tests/test_upload_converter.py
python tests/test_examples.py
# in a scratch database schema, from tests/:
#   @oraas_utl_unit_tests.sql      then      @oraas_utl_upload_tests.sql
```

## Status

Converter and examples are tested offline and checked against an open-source PL/SQL grammar
(`tools/plsql_syntax_check`). Run the SQL tests on your target database before relying on the
shim. Every converted unit must be compiled and compared with legacy output before release.

## Documentation

`references/design.md` (how it works), `references/codes.md` (every refusal and warning),
`references/adapter-guide.md` (connecting your system), `references/decisions.md` (behaviour
choices), `references/publishing.md` (keeping private names out).

## Install as a Claude skill

Package the folder (`SKILL.md` at the top level of the folder) as a zip named
`oraas-utl-file-migration.skill`, then add it in your Claude skill settings, or clone this
repository into your Claude Code skills folder (for example `~/.claude/skills/`).

## License

MIT, see LICENSE.
