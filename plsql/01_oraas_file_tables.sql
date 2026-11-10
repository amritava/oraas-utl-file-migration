-- =============================================================================
-- ORAAS UTL_FILE migration - storage objects owned by the shim
-- -----------------------------------------------------------------------------
-- ORAAS_FILE_OUT : one row per file a converted unit produced (download side).
--                  Your integration (adapter, scheduler job, external service)
--                  delivers the content and updates STATUS.
-- ORAAS_FILE_IN  : one row per line of an incoming file (upload side). Your
--                  loader inserts the lines before the converted unit runs.
--                  If you already have such a table, replace this table by a
--                  simple updatable VIEW named ORAAS_FILE_IN with these columns.
-- ORAAS_FILE_LOG : messages written by the default adapter.
-- Requires Oracle 12.1+ (identity columns). Tested shapes only; adjust storage
-- clauses and sizes to your standards.
-- =============================================================================

CREATE SEQUENCE oraas_run_seq;

CREATE TABLE oraas_file_out (
  file_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id          NUMBER          NOT NULL,           -- one per outermost converted call
  unit_name       VARCHAR2(400)   NOT NULL,           -- converted program unit
  interface_code  VARCHAR2(128),
  location        VARCHAR2(4000),                     -- legacy directory argument of FOPEN
  file_name       VARCHAR2(4000)  NOT NULL,
  business_date   VARCHAR2(30),
  context         VARCHAR2(4000),                     -- NAME=value; pairs from the unit's parameters
  content         NCLOB,                              -- NULL for an empty (0-byte) file
  byte_count      NUMBER          NOT NULL,           -- bytes in the database character set
  is_empty        VARCHAR2(1)     NOT NULL CHECK (is_empty IN ('Y', 'N')),
  status          VARCHAR2(20)    DEFAULT 'READY' NOT NULL,  -- READY / SENT / FAILED (yours to manage)
  status_text     VARCHAR2(4000),
  created_at      TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL
);
CREATE INDEX oraas_file_out_ix1 ON oraas_file_out (status, created_at);

CREATE TABLE oraas_file_in (
  interface_code  VARCHAR2(128)   NOT NULL,           -- converted unit name in capitals by default
  file_name       VARCHAR2(1000)  NOT NULL,
  load_id         VARCHAR2(256)   NOT NULL,           -- one value per load of one file
  line_no         NUMBER          NOT NULL,           -- 1..n, file order
  line_text       VARCHAR2(4000 CHAR),
  loaded_at       DATE            DEFAULT SYSDATE NOT NULL,
  processed_flag  VARCHAR2(1)     DEFAULT 'N' NOT NULL  -- N new / Y processed / E error
);
CREATE INDEX oraas_file_in_ix1 ON oraas_file_in (interface_code, file_name, load_id, line_no);
CREATE INDEX oraas_file_in_ix2 ON oraas_file_in (interface_code, processed_flag, file_name);

CREATE TABLE oraas_file_log (
  log_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  logged_at  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  run_id     NUMBER,
  message    VARCHAR2(4000)
);
