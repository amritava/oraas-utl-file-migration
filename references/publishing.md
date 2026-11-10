# Keeping this skill free of private names

The skill is generic. Names from the system you migrate (tables, procedures, schemas, products,
companies, countries, people) must never enter this repository, its history, its examples or
its package. They belong in your private copies of the recipes and your adapter.

## Deny list

Keep a private text file outside the repository, for example `~/private/oraas_denylist.txt`:

```
# one word per line (plain text, case-insensitive), or re:<regular expression>
MY_REAL_TABLE_NAME
MY_REAL_HANDOFF_PROC
re:\bMYCOMPANY\w*
```

## Check before every commit and every release

```bash
python scripts/leak_check.py --denylist ~/private/oraas_denylist.txt .
python scripts/leak_check.py --denylist ~/private/oraas_denylist.txt dist/oraas-utl-file-migration.skill
```

As a git hook (`.git/hooks/pre-commit`, make it executable):

```bash
#!/bin/sh
exec python scripts/leak_check.py --denylist "$HOME/private/oraas_denylist.txt" .
```

## Other rules

- Start the repository fresh; never push folders, zips or history that contained real code.
- Examples and tests use invented units only.
- Strip author/company metadata from any document you add (`docProps/core.xml` in .docx).
- Make the repository public only with your employer's written permission if the work was done
  for an employer.
