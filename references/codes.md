# Converter statuses, refusals and warnings

## File status (batch summary)

| Status | Output written | Meaning |
|---|---|---|
| CONVERTED | yes | No warnings |
| CONVERTED_WITH_WARNINGS | yes | Read every warning before deploying |
| REVIEW_REQUIRED | no | Refused; `blocker` in the report gives code and line |
| UPLOAD_SCOPE | no | Reads files; run with `--direction upload` |
| NO_UTL_FILE | no | Nothing to convert |
| ALREADY_MIGRATED_MANUAL | no | Uses a `manual_markers` object and no UTL_FILE: hand-migrated, not certified |
| ALREADY_CONVERTED | no | Has the generated header |
| SHARED_HELPER | no | Defines a `shared_objects` object |
| TOOL_ERROR | no | Converter defect; traceback in the report |

The batch log also lists DUPLICATE OBJECTS (same unit in several files): deploy only one.

## Refusals (REVIEW_REQUIRED)

| Code | Cause | Fix |
|---|---|---|
| BYTE_MODE | rb/wb/ab, GET_RAW, PUT_RAW, FSEEK | Needs a BLOB design |
| UPLOAD_SCOPE | Read calls in a download run | Rerun with `--direction upload` |
| DIRECTORY_DEPENDENCY | BFILENAME, DBMS_LOB file calls, external tables, CREATE DIRECTORY, DBMS_DATAPUMP... | Redesign; unrelated to UTL_FILE |
| NOT_TEXT | Word/zip/binary input | Export the unit from the database as text |
| MIXED_CONVERSION | Uses ORAAS_UTL or a `manual_markers` object and still uses UTL_FILE | Restore the original source |
| NAME_COLLISION | `l_oraas_frame` already exists | Rename it in the source or change `frame_variable` |
| PACKAGE_LEVEL_HANDLE | File handle declared at package level | Manual design (file spans calls) |
| PACKAGE_SPEC_FILE_TYPE | UTL_FILE in a package specification | Manual design |
| PACKAGE_INIT_FILE | UTL_FILE in a package initialisation block | Manual design |
| HANDLE_ESCAPES_FRAME | Returns a handle or has an OUT handle and opens files | Let the caller open the file |
| OPEN_IN_DECLARATION | FOPEN in a declaration initialiser | Move FOPEN into the body |
| AMBIGUOUS_STATUS | Two status OUT parameters | Keep one alias in the rules |
| STATUS_NOT_NUMERIC | Text status without `char_success_expression` | Add the expression to the rules |
| SESSION_PARAM_PACKAGE | Package subprogram needs the session parameter | Change spec and body by hand |
| SESSION_PARAM_OUT | Existing session parameter is OUT | Rename, or change `session.parameter` |
| CONDITIONAL_COMPILATION | `$IF` | Convert by hand |
| UNSUPPORTED_MEMBER / UNSUPPORTED_REFERENCE | Unknown UTL_FILE member or odd qualification | Read the line |
| DYNAMIC_SPLIT / DYNAMIC_UNSUPPORTED | UTL_FILE assembled from string pieces, or unsupported in dynamic SQL | Convert by hand |
| UNSUPPORTED_UNIT | UTL_FILE in a trigger or type body | Convert by hand |
| PARSE_ERROR / LEX_ERROR | Source cannot be parsed | Often SQL*Plus text or unbalanced blocks |
| SELF_CHECK_FAILED / INTERNAL | Output did not re-parse | Converter defect: report it |
| OUTPUT_EXISTS | Output from an earlier run | Rerun with `--overwrite` |

## Warnings

| Code | Meaning / action |
|---|---|
| IMPLICIT_CLOSE | Unit never calls FCLOSE; open files are released at normal exit. Check content |
| STATUS_UNGATED | No status parameter: files released on every normal exit |
| STATUS_CHAR / STATUS_ANCHORED_TYPE | Text or %TYPE status; success test shown in the report |
| EXTERNAL_FREMOVE / _FRENAME / _FCOPY / _FGETATTR | Acts only on files of this session; old-file housekeeping is lost |
| APPEND_MODE | Mode 'a' appends only to content written in this session |
| MODE_RUNTIME | Open mode is not a literal |
| DYNAMIC_SQL_REWRITTEN | UTL_FILE renamed inside a dynamic PL/SQL literal; test that path |
| PUBLIC_HANDLE_PARAMETER | Signature changes to ORAAS_UTL.FILE_TYPE; convert all callers together |
| FUNCTION_UNIT | END_UNIT runs before the RETURN expression |
| NO_DISPOSITION | Reads input files but never moves them; marks come only from MARK_INPUT |
| READER_WITHOUT_LISTING / LISTING_WITHOUT_READER | Listing and reading in different units: same interface code needed (`interface_overrides`) |
| DIR_LIST_NAMED_ARGS | Listing procedure called with named arguments; keep the parameter name |
| SESSION_VAR_SIZE | Variable receiving the load id is too small |
| USERENV_SESSION_REPLACED | USERENV('SESSIONID') replaced inside an expression |
| MARK_INPUT_SKIPPED | No MARK_INPUT generated for an input FCLOSE; add it by hand |
| MARK_INPUT_STATUS_SHADOWED | Success test refers to a nested routine's parameter |

INFO findings (DYNAMIC_SQL_PRESENT, SESSION_PARAM_ADDED, MARK_INPUT_ADDED, INPUT_DISPOSITION, ...)
describe what was done and need no action.
