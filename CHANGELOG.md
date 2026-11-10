# Changelog

## 1.0.0
- First generic release: ORAAS_UTL shim with its own tables (ORAAS_FILE_OUT, ORAAS_FILE_IN,
  ORAAS_FILE_LOG) and a site adapter interface (ORAAS_UTL_ADAPTER).
- Write side: buffered files, release on success, empty files, nested units, stale-frame cleanup.
- Read side: GET_LINE from ORAAS_FILE_IN with UTL_FILE error semantics, LIST_INPUT_FILES,
  MARK_INPUT and dispositions through FRENAME / FCOPY + FREMOVE.
- Batch converter for download and upload directions with configurable recipes; session/load-id
  parameter and MARK_INPUT generation for uploads.
- Invented examples, Python converter tests, SQL shim tests, leak check.
