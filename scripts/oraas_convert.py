#!/usr/bin/env python3
"""
ORAAS UTL_FILE batch converter (oraas-utl-file-migration skill).

Converts every PL/SQL source in a folder from UTL_FILE to the ORAAS_UTL shim,
for databases without UTL_FILE (Oracle Autonomous Database / ORAAS).

    python oraas_convert.py --direction download InputForDownload
    python oraas_convert.py --direction upload   InputForUpload

For every unit that opens, copies or lists files:
  1. Renames every active UTL_FILE reference to ORAAS_UTL (same API, same
     exception codes), including SYS.UTL_FILE and UTL_FILE inside dynamic
     PL/SQL string literals.
  2. Declares one frame variable and calls ORAAS_UTL.BEGIN_UNIT first.
  3. Calls ORAAS_UTL.END_UNIT on every exit: end of body, every RETURN, the end
     of every main exception handler, before every RAISE in a main handler.
  4. Adds WHEN OTHERS THEN end_unit(FALSE); RAISE; when the main block cannot
     catch every exception.
  Upload direction, additionally (configurable):
  5. Adds a session/load-id IN parameter and replaces USERENV('SESSIONID').
  6. Adds ORAAS_UTL.MARK_INPUT after every FCLOSE of an input file.
Everything else (business logic, wrappers, handlers) is left byte-for-byte.

Units that cannot be converted safely are NOT written to the output folder;
their <file>.report.json says why. Standard library only, no database access.
Output is "generated, unverified" until compiled and compared with legacy.
"""
import argparse
import csv
import datetime
import difflib
import hashlib
import json
import re
import sys
import traceback
from bisect import bisect_right
from dataclasses import dataclass, field
from pathlib import Path

TOOL_VERSION = "1.0.0"


# =============================================================================
# Errors and findings
# =============================================================================
class ReviewRequired(Exception):
    """The unit cannot be converted automatically. Nothing is written."""

    def __init__(self, code, message, line=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.line = line


@dataclass
class Finding:
    level: str          # INFO | WARN | BLOCK
    code: str
    message: str
    line: int = None

    def as_dict(self):
        d = {"level": self.level, "code": self.code, "message": self.message}
        if self.line:
            d["line"] = self.line
        return d


# =============================================================================
# Lexer
# =============================================================================
@dataclass
class Tok:
    kind: str           # id | qid | str | num | op
    value: str
    start: int
    end: int

    @property
    def up(self):
        if self.kind == "id":
            return self.value.upper()
        if self.kind == "qid":
            return self.value[1:-1]
        return self.value


_ID = re.compile(r"[A-Za-z][A-Za-z0-9_$#]*")
_NUM = re.compile(r"\d+(?:\.\d+)?(?:[eE][+-]?\d+)?")
_OPS = (":=", "=>", "<>", "!=", "~=", "^=", "<=", ">=", "||", "..", "**")
_QQ = re.compile(r"[nN]?[qQ]'")
_CLOSERS = {"[": "]", "{": "}", "(": ")", "<": ">"}


class Source:
    """Source text, its tokens and line lookup."""

    def __init__(self, text):
        self.text = text
        self.toks = self._lex(text)
        self._nl = [m.start() for m in re.finditer("\n", text)]

    def line(self, pos):
        return bisect_right(self._nl, pos - 1) + 1

    def _lex(self, s):
        toks, i, n = [], 0, len(s)
        while i < n:
            c = s[i]
            if c.isspace():
                i += 1
                continue
            if s.startswith("--", i):
                j = s.find("\n", i)
                i = n if j < 0 else j
                continue
            if s.startswith("/*", i):
                j = s.find("*/", i + 2)
                if j < 0:
                    raise ReviewRequired("LEX_ERROR", "Unterminated /* comment", self._line_of(s, i))
                i = j + 2
                continue
            start = i
            m = _QQ.match(s, i)
            if m:
                a = m.end()
                if a >= n:
                    raise ReviewRequired("LEX_ERROR", "Malformed q-quoted literal", self._line_of(s, i))
                close = _CLOSERS.get(s[a], s[a]) + "'"
                j = s.find(close, a + 1)
                if j < 0:
                    raise ReviewRequired("LEX_ERROR", "Unterminated q-quoted literal", self._line_of(s, i))
                i = j + 2
                toks.append(Tok("str", s[start:i], start, i))
                continue
            if c == "'" or (c in "nN" and s.startswith("'", i + 1)):
                i += 2 if c in "nN" else 1
                while True:
                    if i >= n:
                        raise ReviewRequired("LEX_ERROR", "Unterminated string literal", self._line_of(s, start))
                    if s.startswith("''", i):
                        i += 2
                    elif s[i] == "'":
                        i += 1
                        break
                    else:
                        i += 1
                toks.append(Tok("str", s[start:i], start, i))
                continue
            if c == '"':
                j = s.find('"', i + 1)
                if j < 0:
                    raise ReviewRequired("LEX_ERROR", "Unterminated quoted identifier", self._line_of(s, i))
                i = j + 1
                toks.append(Tok("qid", s[start:i], start, i))
                continue
            m = _ID.match(s, i)
            if m:
                i = m.end()
                toks.append(Tok("id", s[start:i], start, i))
                continue
            m = _NUM.match(s, i)
            if m:
                i = m.end()
                toks.append(Tok("num", s[start:i], start, i))
                continue
            op = next((o for o in _OPS if s.startswith(o, i)), c)
            i += len(op)
            toks.append(Tok("op", op, start, i))
        return toks

    @staticmethod
    def _line_of(s, pos):
        return s.count("\n", 0, pos) + 1


# =============================================================================
# Structure model
# =============================================================================
@dataclass
class Param:
    name: str
    idx: int
    modes: set
    type_up: str
    last: int = -1          # token index of the parameter's last token


@dataclass(eq=False)
class Block:
    start: int              # token index of BEGIN / IF / LOOP / CASE
    kind: str
    parent: object = None
    end: int = -1           # token index of END
    exception: int = -1     # token index of EXCEPTION
    handlers: list = field(default_factory=list)   # [(when_idx, then_idx)]


@dataclass(eq=False)
class Routine:
    kind: str               # PROCEDURE | FUNCTION | BLOCK | PACKAGE BODY
    name: str
    start: int
    parent: object = None
    params: list = field(default_factory=list)
    return_up: str = ""
    is_at: int = -1
    decls: list = field(default_factory=list)       # [(a, b)] token spans
    children: list = field(default_factory=list)
    begin: int = -1
    body: Block = None
    end: int = -1           # token index of the final ';'
    forward: bool = False
    name_end: int = -1      # token index of the last name token
    params_close: int = -1  # token index of the ')' closing the parameter list


@dataclass(eq=False)
class Unit:
    kind: str               # PROCEDURE | FUNCTION | PACKAGE BODY | PACKAGE | OTHER
    name: str
    start: int
    end: int
    routine: Routine = None


STATEMENT_START_PREV = {";", "THEN", "ELSE", "LOOP", "BEGIN", ">", "EXCEPTION"}


class Model:
    """Parses program units, their nested routines and executable blocks."""

    def __init__(self, src: Source):
        self.src = src
        self.t = src.toks
        self.U = [x.up if x.kind in ("id", "op") else None for x in self.t]
        self.n = len(self.t)
        self.blocks = []            # every Block of every body
        self.excluded = []          # (a, b) DECLARE-section token ranges inside bodies
        self.routines = []
        self.units = self._find_units()

    # -- helpers --------------------------------------------------------------
    def kw(self, i, *words):
        return 0 <= i < self.n and self.t[i].kind == "id" and self.U[i] in words

    def line(self, i):
        return self.src.line(self.t[min(i, self.n - 1)].start)

    def fail(self, code, msg, i=None):
        raise ReviewRequired(code, msg, self.line(i) if i is not None else None)

    def parens(self, i):
        """i at '('. Returns (close_idx, [(a, b) arg spans at depth 1])."""
        depth, start, parts = 0, i + 1, []
        for j in range(i, self.n):
            v = self.U[j]
            if v == "(":
                depth += 1
            elif v == ")":
                depth -= 1
                if depth == 0:
                    if j > start:
                        parts.append((start, j))
                    return j, parts
            elif v == "," and depth == 1:
                parts.append((start, j))
                start = j + 1
        self.fail("PARSE_ERROR", "Unbalanced parentheses", i)

    def to_semicolon(self, i):
        depth = 0
        while i < self.n:
            if self.U[i] == "(":
                depth += 1
            elif self.U[i] == ")":
                depth -= 1
            elif self.U[i] == ";" and depth == 0:
                return i
            i += 1
        self.fail("PARSE_ERROR", "Missing ';'", self.n - 1)

    # -- units ----------------------------------------------------------------
    def _find_units(self):
        units, i = [], 0
        while i < self.n:
            if self.kw(i, "CREATE"):
                j = i + 1
                if self.kw(j, "OR") and self.kw(j + 1, "REPLACE"):
                    j += 2
                while self.kw(j, "EDITIONABLE", "NONEDITIONABLE", "EDITIONING", "FORCE", "NOFORCE"):
                    j += 1
                if self.kw(j, "PROCEDURE", "FUNCTION"):
                    r = self.parse_routine(j, None)
                    units.append(Unit(r.kind, r.name, i, r.end, r))
                    i = r.end + 1
                    continue
                if self.kw(j, "PACKAGE"):
                    if self.kw(j + 1, "BODY"):
                        r = self.parse_package_body(j)
                        units.append(Unit("PACKAGE BODY", r.name, i, r.end, r))
                    else:
                        end = self.package_spec_end(j)
                        units.append(Unit("PACKAGE", self.t[j + 1].up, i, end))
                        i = end
                    i = units[-1].end + 1
                    continue
                if self.kw(j, "TRIGGER", "TYPE", "LIBRARY", "JAVA"):
                    units.append(Unit("OTHER", self.U[j] or "", i, self.n - 1))
                    return units          # not parsed further; reviewed if it uses UTL_FILE
                i = self.to_semicolon_or_slash(j)
                continue
            i += 1
        if not units:
            for k in range(self.n):
                if self.kw(k, "PROCEDURE", "FUNCTION"):
                    r = self.parse_routine(k, None)
                    units.append(Unit(r.kind, r.name, k, r.end, r))
                    break
                if self.kw(k, "PACKAGE"):
                    if self.kw(k + 1, "BODY"):
                        r = self.parse_package_body(k)
                        units.append(Unit("PACKAGE BODY", r.name, k, r.end, r))
                    break
        return units

    def to_semicolon_or_slash(self, i):
        while i < self.n and self.U[i] not in (";", "/"):
            i += 1
        return i + 1

    def package_spec_end(self, j):
        depth = 0
        i = j + 2
        while i < self.n:
            if self.kw(i, "CASE"):
                depth += 1
            elif self.kw(i, "END"):
                if depth:
                    depth -= 1
                else:
                    return self.to_semicolon(i)
            i += 1
        self.fail("PARSE_ERROR", "Package specification without END", j)

    def read_name(self, i):
        """Name at i, optionally schema-qualified. Returns (name, next_index)."""
        if self.t[i].kind not in ("id", "qid"):
            self.fail("PARSE_ERROR", "Expected a program unit name", i)
        name, i = self.t[i].up, i + 1
        if self.U[i] == "." and i + 1 < self.n and self.t[i + 1].kind in ("id", "qid"):
            name, i = self.t[i + 1].up, i + 2
        return name, i

    def parse_routine(self, k, parent):
        kind = self.U[k]
        name, i = self.read_name(k + 1)
        r = Routine(kind, name, k, parent)
        r.name_end = i - 1
        self.routines.append(r)
        if self.U[i] == "(":
            close, spans = self.parens(i)
            r.params = [self.param(a, b) for a, b in spans]
            r.params_close = close
            i = close + 1
        depth, ret_from = 0, None
        while i < self.n:
            v = self.U[i]
            if v == "(":
                depth += 1
            elif v == ")":
                depth -= 1
            elif depth == 0 and self.kw(i, "RETURN") and ret_from is None:
                ret_from = i + 1
            elif depth == 0 and (self.kw(i, "IS", "AS") or v == ";"):
                break
            i += 1
        if ret_from is not None:
            r.return_up = " ".join(self.U[x] or "" for x in range(ret_from, i))
        if i >= self.n or self.U[i] == ";":
            r.forward, r.end = True, i
            return r
        r.is_at = i
        if self.kw(i + 1, "LANGUAGE", "EXTERNAL"):
            r.forward, r.end = True, self.to_semicolon(i)
            return r
        self.parse_declarations(r, i + 1)
        return r

    def param(self, a, b):
        modes, j = set(), a + 1
        while j < b and self.kw(j, "IN", "OUT", "NOCOPY"):
            modes.add(self.U[j])
            j += 1
        if not modes:
            modes.add("IN")
        type_up = " ".join(self.U[x] or "" for x in range(j, b))
        return Param(self.t[a].up, a, modes, type_up, b - 1)

    def parse_package_body(self, k):
        name, i = self.read_name(k + 2)
        r = Routine("PACKAGE BODY", name, k, None)
        while i < self.n and not self.kw(i, "IS", "AS"):
            i += 1
        r.is_at = i
        self.parse_declarations(r, i + 1, allow_end=True)
        return r

    def parse_declarations(self, owner, i, allow_end=False):
        while i < self.n:
            if self.kw(i, "BEGIN"):
                owner.begin = i
                owner.body = self.parse_body(owner, i)
                owner.end = self.to_semicolon(owner.body.end)
                return
            if allow_end and self.kw(i, "END"):
                owner.end = self.to_semicolon(i)
                return
            if self.kw(i, "PROCEDURE", "FUNCTION"):
                child = self.parse_routine(i, owner)
                owner.children.append(child)
                i = child.end + 1
                continue
            if self.U[i] == "$":
                self.fail("CONDITIONAL_COMPILATION", "Conditional compilation ($IF) is not supported", i)
            j = self.to_semicolon(i)
            owner.decls.append((i, j + 1))
            i = j + 1
        self.fail("PARSE_ERROR", f"{owner.name}: missing BEGIN", owner.start)

    def parse_body(self, owner, begin):
        root = Block(begin, "BEGIN")
        self.blocks.append(root)
        stack, i = [root], begin + 1
        while i < self.n:
            v = self.U[i]
            if v == "$":
                self.fail("CONDITIONAL_COMPILATION", "Conditional compilation ($IF) is not supported", i)
            if self.kw(i, "DECLARE"):
                blk = Routine("BLOCK", "<DECLARE>", i, owner)
                self.parse_declarations(blk, i + 1)
                self.excluded.append((i, blk.begin))
                i = blk.end + 1
                continue
            if self.kw(i, "BEGIN", "IF", "LOOP", "CASE"):
                b = Block(i, v, stack[-1])
                self.blocks.append(b)
                stack.append(b)
            elif self.kw(i, "EXCEPTION") and stack[-1].kind == "BEGIN" and stack[-1].exception < 0:
                stack[-1].exception = i
            elif (self.kw(i, "WHEN") and stack[-1].kind == "BEGIN" and stack[-1].exception >= 0
                  and self.U[i - 1] in (";", "EXCEPTION")):
                j = i + 1
                while j < self.n and not self.kw(j, "THEN"):
                    j += 1
                stack[-1].handlers.append((i, j))
            elif self.kw(i, "END"):
                b = stack.pop()
                suffix = self.U[i + 1] if i + 1 < self.n else ""
                if b.kind in ("IF", "LOOP") and suffix != b.kind:
                    self.fail("PARSE_ERROR", f"END does not close {b.kind}", i)
                if b.kind == "BEGIN" and suffix in ("IF", "LOOP", "CASE"):
                    self.fail("PARSE_ERROR", f"END {suffix} closes a BEGIN block", i)
                b.end = i
                if not stack:
                    return root
                if suffix in ("IF", "LOOP", "CASE") and self.t[i + 1].kind == "id":
                    i += 1
            i += 1
        self.fail("PARSE_ERROR", "Unterminated executable block", begin)

    # -- queries --------------------------------------------------------------
    def in_excluded(self, i):
        return any(a <= i < b for a, b in self.excluded)

    def stmt_start(self, i):
        return self.U[i - 1] in STATEMENT_START_PREV

    def caught_inside(self, i, region_start):
        """True if a nested BEGIN block (starting after region_start) may catch an exception at i."""
        for b in self.blocks:
            if (b.kind == "BEGIN" and b.start > region_start and b.exception >= 0
                    and b.start < i < b.exception):
                return True
        return False


# =============================================================================
# Edits
# =============================================================================
class Edits:
    def __init__(self, text):
        self.text = text
        self.items = []     # (a, b, new, order)

    def replace(self, a, b, new):
        for x, y, _, _ in self.items:
            if x != y and a < y and x < b:
                raise ReviewRequired("INTERNAL", "Overlapping edits")
        self.items.append((a, b, new, len(self.items)))

    def insert(self, pos, new):
        self.items.append((pos, pos, new, len(self.items)))

    def render(self):
        out, last = [], 0
        for a, b, new, _ in sorted(self.items, key=lambda e: (e[0], e[1] != e[0], e[3])):
            out.append(self.text[last:a])
            out.append(new)
            last = max(last, b)
        out.append(self.text[last:])
        return "".join(out)


# =============================================================================
# Converter
# =============================================================================
class Converter:
    def __init__(self, rules):
        self.r = rules
        self.pkg = rules["package"]
        self.frame = rules["frame_variable"]
        m = rules["members"]
        self.supported = set(m["supported"]) | set(m["exceptions"])
        self.creates = set(m["creates_file"])
        self.closes = set(m["closes_file"])
        self.ext_warn = set(m["external_effect_warn"])
        self.upload = set(m["upload_scope"])
        self.blocked_modes = set(m["blocked_open_modes"])
        self.reads = set(m.get("reads_file", []))
        self.dispositions = set(m.get("disposition", []))
        self.direction = rules["direction"]
        self.manual_markers = [x.upper() for x in rules.get("manual_markers", [])]
        self.shared_objects = [x.upper() for x in rules.get("shared_objects", [])]
        self.triggers = [x.upper() for x in rules.get("frame_trigger_calls", [])]
        self.interface_overrides = {k.upper(): v for k, v in rules.get("interface_overrides", {}).items()
                                    if k != "comment"}
        self.warn_modes = set(m["warn_open_modes"])
        d = rules["directory_dependencies"]
        self.dir_calls = [c.upper() for c in d["calls"]]
        self.dir_literals = [re.compile(p, re.I) for p in d["literal_patterns"]]

    # ------------------------------------------------------------------ entry
    def convert(self, text):
        """Returns (new_text or None, report dict). Raises ReviewRequired."""
        rep = {"findings": [], "units": [], "operations": {}}
        F = rep["findings"]

        def add(level, code, msg, line=None):
            F.append(Finding(level, code, msg, line))

        if any(mk in text for mk in [self.r["marker"]] + self.r.get("known_markers", [])):
            rep["status"] = "ALREADY_CONVERTED"
            return None, rep
        for obj in self.shared_objects:
            if re.search(r"\b(procedure|function)\s+(\w+\s*\.\s*)?" + obj + r"\b", text, re.I):
                rep["status"] = "SHARED_HELPER"
                return None, rep
        has_trigger_text = any(re.search(r"\b" + c + r"\b", text, re.I) for c in self.triggers)
        if not re.search(r"utl_file", text, re.I) and not has_trigger_text:
            rep["status"] = ("ALREADY_MIGRATED_MANUAL"
                             if any(re.search(r"\b" + mk + r"\b", text, re.I) for mk in self.manual_markers)
                             else "NO_UTL_FILE")
            return None, rep

        src = Source(text)
        model = Model(src)
        t, U = model.t, model.U
        rep["objects"] = [f"{u.kind} {u.name}" for u in model.units]

        active = [i for i, x in enumerate(t) if x.kind == "id" and U[i] == "UTL_FILE"]
        str_hits = [i for i, x in enumerate(t) if x.kind == "str" and re.search(r"utl_file", x.value, re.I)]
        ids = {U[i] for i, x in enumerate(t) if x.kind == "id"}

        trig = [i for i, x in enumerate(t) if x.kind == "id" and U[i] in self.triggers
                and U[i - 1] != "." and model.stmt_start(i)]
        manual = "ALREADY_MIGRATED_MANUAL" if any(mk in ids for mk in self.manual_markers) else "NO_UTL_FILE"
        if not active and not str_hits and not trig:
            rep["status"] = manual
            return None, rep
        if not active and not trig:
            # UTL_FILE only inside literals: inspect them, but there is nothing active to convert
            for i in str_hits:
                add("INFO", "UTL_FILE_IN_LITERAL", "UTL_FILE appears only inside a string literal; not converted", model.line(i))
            rep["status"] = manual
            return None, rep

        # ---------------------------------------------------- global blockers
        if self.pkg.upper() in ids:
            model.fail("MIXED_CONVERSION", f"Source already references {self.pkg.upper()} and still uses UTL_FILE")
        if self.frame.upper() in ids:
            model.fail("NAME_COLLISION", f"Identifier {self.frame} already exists in the source")
        for mk in self.manual_markers:
            if mk in ids:
                model.fail("MIXED_CONVERSION",
                           f"Source references {mk} (already migrated by hand) and also uses UTL_FILE")
        if not model.units:
            model.fail("PARSE_ERROR", "No PROCEDURE, FUNCTION or PACKAGE BODY found")
        for u in model.units:
            if u.kind == "OTHER" and any(i >= u.start for i in active):
                model.fail("UNSUPPORTED_UNIT", f"UTL_FILE inside a {u.name} unit (trigger/type) is not supported", u.start)
            if u.kind == "PACKAGE" and any(u.start <= i <= u.end for i in active):
                model.fail("PACKAGE_SPEC_FILE_TYPE",
                           "UTL_FILE is used in a package specification (public file handle/type); needs manual design", u.start)

        for i, x in enumerate(t):
            if x.kind != "id":
                continue
            dotted = U[i] + ("." + U[i + 2] if i + 2 < model.n and U[i + 1] == "." and U[i + 2] else "")
            for c in self.dir_calls:
                if dotted == c or (("." not in c) and U[i] == c):
                    model.fail("DIRECTORY_DEPENDENCY", f"{c} needs an Oracle directory and does not work on ORAAS", i)
        for i, x in enumerate(t):
            if x.kind == "str":
                for p in self.dir_literals:
                    if p.search(x.value):
                        model.fail("DIRECTORY_DEPENDENCY", f"Dynamic SQL uses '{p.pattern}' (directory object)", i)
        if any(x.kind == "id" and U[i] in ("EXECUTE", "DBMS_SQL") for i, x in enumerate(t)):
            add("INFO", "DYNAMIC_SQL_PRESENT",
                "Dynamic SQL present. Literal UTL_FILE code is converted; SQL built from variables at runtime cannot be checked")

        edits = Edits(text)

        # ------------------------------------------------- active references
        ops = []     # (member, token idx)
        for i in active:
            a = i
            if U[i - 1] == ".":
                if U[i - 2] == "SYS":
                    a = i - 2
                else:
                    model.fail("UNSUPPORTED_REFERENCE", f"UTL_FILE qualified by {t[i-2].value}", i)
            if i + 2 >= model.n or U[i + 1] != "." or t[i + 2].kind != "id":
                model.fail("UNSUPPORTED_REFERENCE", "UTL_FILE used without a member name", i)
            member = U[i + 2]
            if member in self.upload:
                if self.direction == "upload":
                    model.fail("BYTE_MODE", f"UTL_FILE.{member} (binary or positioned read) has no ORAAS_UTL equivalent", i)
                model.fail("UPLOAD_SCOPE", f"UTL_FILE.{member} reads files (upload). Run the upload converter", i)
            if member not in self.supported:
                model.fail("UNSUPPORTED_MEMBER", f"UTL_FILE.{member} has no ORAAS_UTL equivalent", i)
            if member in ("FOPEN", "FOPEN_NCHAR"):
                self.check_mode(model, i, add)
            if member in self.ext_warn:
                add("WARN", f"EXTERNAL_{member}",
                    f"{member} acts only on files produced in this session; a file from an earlier run is not touched. Verify intent",
                    model.line(i))
            ops.append((member, i))
            rep["operations"].setdefault(member, []).append(model.line(i))
            edits.replace(t[a].start, t[i].end, self.case_like(t[i].value))
        for i in trig:
            ops.append(("LISTING_CALL", i))
            rep["operations"].setdefault(t[i].up, []).append(model.line(i))
            if model.U[i + 1] == "(" :
                _, args = model.parens(i + 1)
                if any(b - a >= 3 and model.U[a + 1] == "=>" for a, b in args):
                    add("WARN", "DIR_LIST_NAMED_ARGS",
                        f"{t[i].value} is called with named arguments; the replacement's parameter name must match",
                        model.line(i))

        # -------------------------------------------- UTL_FILE inside literals
        dyn_members = []      # (member, token idx)
        for i in str_hits:
            v = t[i].value
            if re.search(r"utl_?\s*'?\s*$", v, re.I) and not re.search(r"utl_file", v, re.I):
                model.fail("DYNAMIC_SPLIT", "A string literal ends with 'UTL_' (dynamic code split across literals)", i)
            code = re.findall(r"\butl_file\s*\.\s*([A-Za-z_]+)", v, re.I)
            looks_code = code and re.search(r"\b(begin|declare)\b|;", v, re.I)
            if not looks_code:
                add("INFO", "UTL_FILE_IN_MESSAGE", "UTL_FILE mentioned in a text literal (message); left unchanged", model.line(i))
                continue
            for mem in (c.upper() for c in code):
                if mem in self.upload or mem not in self.supported:
                    model.fail("DYNAMIC_UNSUPPORTED", f"Dynamic PL/SQL uses UTL_FILE.{mem}", i)
                dyn_members.append((mem, i))
            new = re.sub(r"(\bsys\s*\.\s*)?\butl_file\b", lambda m: self.case_like(m.group(0).split(".")[-1].strip()),
                         v, flags=re.I)
            edits.replace(t[i].start, t[i].end, new)
            add("WARN", "DYNAMIC_SQL_REWRITTEN",
                "UTL_FILE inside a dynamic PL/SQL literal was renamed to ORAAS_UTL. Test this path explicitly", model.line(i))
        for mem, i in dyn_members:
            rep["operations"].setdefault(mem + " (dynamic)", []).append(model.line(i))

        # ----------------------------------------------------- frame owners
        owners = []
        for u in model.units:
            if u.kind in ("PROCEDURE", "FUNCTION"):
                owners.append((u.routine, u.name))
            elif u.kind == "PACKAGE BODY":
                pb = u.routine
                for a, b in pb.decls:
                    if any(a <= i < b for i in active):
                        model.fail("PACKAGE_LEVEL_HANDLE",
                                   "UTL_FILE used at package level (shared file handle across calls); needs manual design", a)
                if pb.body and any(pb.begin <= i <= pb.body.end for i in active):
                    model.fail("PACKAGE_INIT_FILE", "UTL_FILE used in the package initialization section", pb.begin)
                for ch in pb.children:
                    if not ch.forward:
                        owners.append((ch, f"{pb.name}.{ch.name}"))

        all_ops = ops + dyn_members
        framed = 0
        for routine, label in owners:
            span_ops = [(m, i) for m, i in all_ops if routine.start <= i <= routine.end]
            if not span_ops:
                continue
            if not any(m in self.creates or m == "LISTING_CALL" for m, _ in span_ops):
                rep["units"].append({"unit": label, "frame": False,
                                     "reason": "uses file handles but never opens/copies a file; rename only"})
                self.check_handle_signature(model, routine, label, add, owner_opens=False)
                continue
            self.check_handle_signature(model, routine, label, add, owner_opens=True)
            sess = None
            if self.direction == "upload" and self.r.get("session"):
                sess = self.session_rewrite(model, routine, label, edits, add)
            info = self.add_frame(model, routine, label, span_ops, edits, add,
                                  extra_binds=[("p_session_id", sess)] if sess else None)
            if self.direction == "upload":
                self.upload_checks(model, routine, label, span_ops, add, info)
                if self.r.get("mark_on_close", {}).get("enabled"):
                    self.mark_on_close(model, routine, label, span_ops, edits, add, info, sess)
            rep["units"].append(info)
            framed += 1

        # ------------------------------------------------------------ render
        new_text = edits.render()
        nl = "\r\n" if "\r\n" in text else "\n"
        header = (f"-- {self.r['marker']} v{TOOL_VERSION} {datetime.date.today().isoformat()}: "
                  f"UTL_FILE -> {self.pkg.upper()}; {framed} frame(s). Compile and byte-compare before release.{nl}")
        new_text = header + new_text
        self.verify(new_text, model)
        rep["status"] = "CONVERTED_WITH_WARNINGS" if any(f.level == "WARN" for f in F) else "CONVERTED"
        rep["edit_count"] = len(edits.items)
        return new_text, rep

    # ------------------------------------------------------------- checks
    def case_like(self, original):
        return self.pkg.upper() if not original.islower() else self.pkg.lower()

    def check_mode(self, model, i, add):
        if model.U[i + 3] != "(":
            model.fail("UNSUPPORTED_REFERENCE", "FOPEN without argument list", i)
        _, args = model.parens(i + 3)
        mode = None
        for n, (a, b) in enumerate(args):
            if b - a >= 3 and model.U[a + 1] == "=>":
                if model.U[a] == "OPEN_MODE":
                    mode = (a + 2, b)
            elif n == 2:
                mode = (a, b)
        if mode is None:
            model.fail("PARSE_ERROR", "FOPEN without open_mode", i)
        a, b = mode
        if b - a == 1 and model.t[a].kind == "str":
            lit = model.t[a].value.strip("'").lower()
            if lit in self.blocked_modes:
                model.fail("BYTE_MODE" if "b" in lit else "UPLOAD_SCOPE",
                           f"FOPEN mode '{lit}' is not supported by the {self.direction} converter", i)
            if lit in self.warn_modes:
                add("WARN", "APPEND_MODE",
                    "FOPEN mode 'a': only content written earlier in the same session is appended", model.line(i))
        else:
            add("WARN", "MODE_RUNTIME",
                "FOPEN mode is not a literal; the shim raises at runtime if it is read/byte mode", model.line(i))

    def check_handle_signature(self, model, routine, label, add, owner_opens):
        if "UTL_FILE . FILE_TYPE" in routine.return_up:
            model.fail("HANDLE_ESCAPES_FRAME",
                       f"{label} returns a file handle; the file would outlive its frame", routine.start)
        for p in routine.params:
            if "UTL_FILE . FILE_TYPE" in p.type_up:
                if "OUT" in p.modes and owner_opens:
                    model.fail("HANDLE_ESCAPES_FRAME",
                               f"{label}: OUT file handle parameter {p.name}; the file would outlive its frame", p.idx)
                add("WARN", "PUBLIC_HANDLE_PARAMETER",
                    f"{label}: parameter {p.name} changes type to {self.pkg.upper()}.FILE_TYPE; every caller must be converted in the same release",
                    model.line(p.idx))

    # ------------------------------------------------------------ upload
    def fopen_mode(self, model, i):
        """Literal FOPEN mode (lower case) or None when not a literal."""
        if model.U[i + 3] != "(":
            return None
        _, args = model.parens(i + 3)
        for n, (a, b) in enumerate(args):
            if b - a >= 3 and model.U[a + 1] == "=>":
                if model.U[a] == "OPEN_MODE" and b - a == 3 and model.t[a + 2].kind == "str":
                    return model.t[a + 2].value.strip("'").lower()
            elif n == 2 and b - a == 1 and model.t[a].kind == "str":
                return model.t[a].value.strip("'").lower()
        return None

    def unit_writes(self, model, span_ops):
        """True if the unit opens a file for writing (mode not a literal counts as writing)."""
        return any(m in ("FOPEN", "FOPEN_NCHAR") and (self.fopen_mode(model, i) or "w") != "r"
                   for m, i in span_ops if model.U[i] == "UTL_FILE")

    def upload_checks(self, model, r, label, span_ops, add, info):
        reads = [i for m, i in span_ops if m in ("FOPEN", "FOPEN_NCHAR") and model.U[i] == "UTL_FILE"
                 and self.fopen_mode(model, i) == "r"]
        lists = [i for m, i in span_ops if m == "LISTING_CALL"]
        moves = [i for m, i in span_ops if m in self.dispositions]
        iface = self.interface_overrides.get(label.upper(), label.upper())
        info["interface_code"] = iface
        info["reads_input_files"] = bool(reads)
        if reads and not moves:
            add("WARN", "NO_DISPOSITION",
                f"{label} reads input files but never moves/removes them (FRENAME/FCOPY+FREMOVE). "
                "Their raw rows stay PROCESSED_FLAG='N' and are read again on every run, as the files stayed in the legacy inbox",
                model.line(reads[0]))
        if reads and not lists:
            add("WARN", "READER_WITHOUT_LISTING",
                f"{label} reads input files but does not list the directory itself. Raw rows are looked up with "
                f"INTERFACE_CODE='{iface}'; if the listing happens in a calling unit, set interface_overrides in the rules",
                model.line(reads[0]))
        if lists and not reads:
            add("WARN", "LISTING_WITHOUT_READER",
                f"{label} lists the directory but reads no file itself; the reading unit must use the same interface code '{iface}'",
                model.line(lists[0]))
        if moves:
            add("INFO", "INPUT_DISPOSITION",
                f"{label}: FRENAME/FCOPY+FREMOVE of an input file sets PROCESSED_FLAG ('E' for an error folder, else 'Y')",
                model.line(moves[0]))


    # ---------------------------------------------------------- upload session
    USERENV_PATTERNS = (("USERENV", "(", "'SESSIONID'", ")"),
                        ("SYS_CONTEXT", "(", "'USERENV'", ",", "'SESSIONID'", ")"))

    def userenv_at(self, model, i):
        """End index (exclusive) of USERENV('SESSIONID') / SYS_CONTEXT('USERENV','SESSIONID') at i, else None."""
        for pat in self.USERENV_PATTERNS:
            j = i
            for want in pat:
                if j >= model.n:
                    break
                tok = model.t[j]
                got = tok.value.upper().replace(" ", "") if tok.kind == "str" else (model.U[j] or "")
                if got != want:
                    break
                j += 1
            else:
                return j
        return None

    def session_rewrite(self, model, r, label, edits, add):
        """Adds the session parameter if missing and replaces USERENV('SESSIONID'). Returns the parameter name."""
        cfg = self.r["session"]
        t, text = model.t, model.src.text
        nl = "\r\n" if "\r\n" in text else "\n"
        tag = cfg.get("comment_tag", "--ORAAS Migration")
        pname = cfg["parameter"].upper()
        have = [p for p in r.params if p.name == pname]
        if have:
            param = t[have[0].idx].value
            if "OUT" in have[0].modes:
                model.fail("SESSION_PARAM_OUT", f"{label}: existing {param} is an OUT parameter", have[0].idx)
            add("INFO", "SESSION_PARAM_EXISTS", f"{label}: {param} already declared ({have[0].type_up}); reused",
                model.line(have[0].idx))
        else:
            if r.parent is not None and r.parent.kind == "PACKAGE BODY":
                model.fail("SESSION_PARAM_PACKAGE",
                           f"{label}: adding {cfg['parameter']} to a package subprogram also needs the package "
                           "specification (and any forward declaration) changed; do it by hand", r.start)
            decl = cfg["declaration"]
            param = decl.split()[0]
            if r.params:
                last = r.params[-1]
                ls = self.line_start(text, t[last.idx].start)
                ind = (self.indent(text, t[last.idx].start) if self.first_on_line(text, t[last.idx])
                       else " " * (t[last.idx].start - ls))
                rest = text[t[last.last].end:self.line_end(text, t[last.last].end)].strip()
                trail = ("  " + tag) if rest == "" else (" /* " + tag.lstrip("-").strip() + " */")
                edits.insert(t[last.last].end, "," + nl + ind + decl + trail)
            else:
                edits.insert(t[r.name_end].end, " (" + decl + ")")
            add("INFO", "SESSION_PARAM_ADDED",
                f"{label}: parameter '{decl}' added; callers must pass the load id of the input files", model.line(r.start))
        # USERENV('SESSIONID') -> parameter
        replaced = 0
        i = r.start
        while i <= r.end:
            j = self.userenv_at(model, i)
            if j is None:
                i += 1
                continue
            if (model.kw(i - 1, "SELECT") and model.stmt_start(i - 1) and model.kw(j, "INTO")
                    and model.t[j + 1].kind in ("id", "qid") and model.kw(j + 2, "FROM")
                    and model.kw(j + 3, "DUAL") and model.U[j + 4] == ";"):
                a, z = i - 1, j + 4
                var = t[j + 1].value
                orig = text[t[a].start:t[z].end]
                ind = self.indent(text, t[a].start)
                commented = ("-- " + orig.replace("\r\n", "\n").replace("\n", nl + ind + "-- ")) + "  " + tag
                edits.replace(t[a].start, t[z].end, commented + nl + ind + f"{var} := {param};  {tag}")
                self.check_session_var(model, r, var, label, add, j + 1)
                replaced += 1
                i = z + 1
                continue
            edits.replace(t[i].start, t[j - 1].end, param)
            add("WARN", "USERENV_SESSION_REPLACED",
                f"{label}: {text[t[i].start:t[j - 1].end]} replaced by {param} inside an expression; verify", model.line(i))
            replaced += 1
            i = j
        if not replaced:
            add("INFO", "NO_USERENV_SESSION", f"{label}: no USERENV('SESSIONID') to replace", model.line(r.start))
        return param

    def check_session_var(self, model, r, var, label, add, at):
        """Warn when the variable receiving the session id is too small for an external session id."""
        name = var.upper()
        scope = r
        for routine in model.routines:
            if routine.start <= at <= routine.end and routine.start >= scope.start:
                scope = routine
        for owner in (scope, r):
            for a, b in owner.decls:
                if model.U[a] == name:
                    decl = " ".join(model.U[x] or model.t[x].value for x in range(a + 1, b))
                    m = re.search(r"NUMBER \( (\d+) \)", decl)
                    v = re.search(r"VARCHAR2? \( (\d+)", decl)
                    if (m and int(m.group(1)) < 10) or (v and int(v.group(1)) < 20):
                        add("WARN", "SESSION_VAR_SIZE",
                            f"{label}: {var} is declared '{decl}'; a session/load id longer than that raises "
                            "VALUE_ERROR at the assignment", model.line(a))
                    return

    # ---------------------------------------------------------- mark on close
    def innermost_routine(self, model, i):
        best = None
        for r in model.routines:
            if not r.forward and r.start <= i <= r.end and (best is None or r.start > best.start):
                best = r
        return best

    def handler_condition(self, model, i):
        """Condition tokens of the innermost exception handler containing i, or None."""
        best, cond = -1, None
        for b in model.blocks:
            if b.exception < 0:
                continue
            for n, (w, th) in enumerate(b.handlers):
                end = b.handlers[n + 1][0] if n + 1 < len(b.handlers) else b.end
                if th < i < end and w > best:
                    best, cond = w, [model.U[x] for x in range(w + 1, th)]
        return cond

    def call_args(self, model, i):
        """Argument spans of the call whose '(' is at i+3 (i = UTL_FILE token)."""
        if model.U[i + 3] != "(":
            return []
        _, args = model.parens(i + 3)
        return args

    def arg(self, model, args, pos, name):
        for n, (a, b) in enumerate(args):
            if b - a >= 3 and model.U[a + 1] == "=>":
                if model.U[a] == name:
                    return (a + 2, b)
            elif n == pos:
                return (a, b)
        return None

    def mark_on_close(self, model, r, label, span_ops, edits, add, info, sess):
        cfg = self.r["mark_on_close"]
        t, U, text = model.t, model.U, model.src.text
        nl = "\r\n" if "\r\n" in text else "\n"
        tag = self.r.get("session", {}).get("comment_tag", "--ORAAS Migration")
        has_move = any(m in self.dispositions for m, _ in span_ops)
        if cfg.get("scope") == "units_without_move" and has_move:
            info["mark_input_calls"] = 0
            return
        # handle variable -> [(mode, filename text, filename token span, routine)]
        opens = {}
        for m, i in span_ops:
            if m in ("FOPEN", "FOPEN_NCHAR") and U[i] == "UTL_FILE":
                a = i - 2 if U[i - 1] == "." and U[i - 2] == "SYS" else i
                if U[a - 1] != ":=":
                    continue
                k = a - 2
                while k > 1 and U[k - 1] == ".":
                    k -= 2
                handle = "".join(U[x] or "" for x in range(k, a - 1))
                span = self.arg(model, self.call_args(model, i), 1, "FILENAME")
                if span is None:
                    continue
                fn = text[t[span[0]].start:t[span[1] - 1].end]
                opens.setdefault(handle, []).append((self.fopen_mode(model, i), fn, span,
                                                     self.innermost_routine(model, i)))
        owner_names = {p.name for p in r.params} | {U[a] for a, b in r.decls if U[a]}
        if sess:
            owner_names.add(sess.upper())
        st_name = info.get("status_parameter")
        ok = info.get("ok_expression") or "TRUE"
        flags = [U[a] for a, b in r.decls if U[a] in [x.upper() for x in cfg.get("error_flag_aliases", [])]]
        succ, fail = cfg["success_flag"], cfg["failure_flag"]
        cond = ok if ok != "TRUE" else ""
        for fl in flags:
            cond += (" AND " if cond else "") + f"NVL({t[[a for a, b in r.decls if U[a] == fl][0]].value}, 'N') <> 'Y'"
        runtime = f"CASE WHEN {cond} THEN '{succ}' ELSE '{fail}' END" if cond else f"'{succ}'"
        done = 0
        for m, i in span_ops:
            if m != "FCLOSE" or U[i] != "UTL_FILE":
                continue
            span = self.arg(model, self.call_args(model, i), 0, "FILE")
            if span is None:
                continue
            handle = "".join(U[x] or "" for x in range(*span))
            cands = opens.get(handle, [])
            reads = [c for c in cands if c[0] == "r"]
            if not reads:
                if any(c[0] is None for c in cands):
                    add("WARN", "MARK_INPUT_SKIPPED",
                        f"{label}: FCLOSE({handle}) - open mode is not a literal; add MARK_INPUT by hand if it is an input file",
                        model.line(i))
                continue
            names = {re.sub(r"\s+", "", c[1]).upper() for c in reads}
            if len(names) > 1:
                add("WARN", "MARK_INPUT_SKIPPED",
                    f"{label}: FCLOSE({handle}) - handle opened with different file names {sorted(names)}; add MARK_INPUT by hand",
                    model.line(i))
                continue
            mode, fname, fspan, open_routine = reads[0]
            close_routine = self.innermost_routine(model, i)
            if close_routine is not open_routine:
                idents = {U[x] for x in range(*fspan) if t[x].kind == "id"}
                if not idents <= owner_names | {"TRIM", "LTRIM", "RTRIM", "UPPER", "LOWER", "SUBSTR"}:
                    add("WARN", "MARK_INPUT_SKIPPED",
                        f"{label}: FCLOSE({handle}) is in another routine than its FOPEN and the file name "
                        f"{fname} may not be visible there; add MARK_INPUT by hand", model.line(i))
                    continue
            hcond = self.handler_condition(model, i)
            eof = hcond is not None and hcond == [x.upper() for x in cfg.get("eof_handlers", ["NO_DATA_FOUND"])]
            flag = runtime if (hcond is None or eof) else f"'{fail}'"
            if st_name and close_routine is not r and close_routine is not None and \
                    any(p.name == st_name for p in close_routine.params):
                add("WARN", "MARK_INPUT_STATUS_SHADOWED",
                    f"{label}: {st_name} in the success test refers to the parameter of {close_routine.name}",
                    model.line(i))
            call = (f"{self.pkg}.mark_input(p_filename => {fname}, p_session => {sess or 'NULL'}, "
                    f"p_flag => {flag}, p_how => '{label}');  {tag}")
            semi = model.to_semicolon(i)
            stmt = i - 2 if U[i - 1] == "." and U[i - 2] == "SYS" else i
            ind = self.indent(text, t[stmt].start)
            le = self.line_end(text, t[semi].end)
            rest = text[t[semi].end:le].strip()
            if rest == "" or rest.startswith("--"):
                edits.insert(le, nl + ind + call)
            else:
                inline = call.replace("  " + tag, " /* " + tag.lstrip("-").strip() + " */")
                edits.insert(t[semi].end, " " + inline)
            done += 1
        info["mark_input_calls"] = done
        info["mark_input_success_test"] = runtime
        if done:
            add("INFO", "MARK_INPUT_ADDED",
                f"{label}: {done} MARK_INPUT call(s) after FCLOSE (success test: {runtime})", model.line(r.start))

    # ------------------------------------------------------------ framing
    def add_frame(self, model, r, label, span_ops, edits, add, extra_binds=None):
        t, U, text = model.t, model.U, model.src.text
        nl = "\r\n" if "\r\n" in text else "\n"
        fr = self.frame
        # FOPEN executed while the declaration section initialises -> before BEGIN_UNIT
        for m, i in span_ops:
            if m in self.creates and r.is_at < i < r.begin and not any(c.start <= i <= c.end for c in r.children):
                model.fail("OPEN_IN_DECLARATION", f"{label}: {m} runs in a declaration initialiser, before the frame exists", i)

        # ---- status gate (files released only on success)
        st = self.r["status"]
        outs = {p.name: p for p in r.params if "OUT" in p.modes}
        found = [a for a in st["code_aliases"] if a in outs]
        if len(found) > 1:
            model.fail("AMBIGUOUS_STATUS", f"{label}: several status parameters {found}; choose one in the rules", r.start)
        if found:
            p = outs[found[0]]
            numeric = re.search(r"\b(NUMBER|INTEGER|INT|PLS_INTEGER|BINARY_INTEGER|NATURAL|NATURALN|POSITIVE|SIMPLE_INTEGER|SMALLINT|DECIMAL|NUMERIC)\b", p.type_up)
            is_char = re.search(r"\b(VARCHAR2|VARCHAR|CHAR|NVARCHAR2)\b", p.type_up)
            if is_char and st.get("char_success_expression"):
                ok = st["char_success_expression"].format(v=t[p.idx].value)
                add("WARN", "STATUS_CHAR", f"{label}: status {p.name} is text; success = {ok}", model.line(p.idx))
            else:
                if not numeric and "%TYPE" not in p.type_up.replace(" ", ""):
                    model.fail("STATUS_NOT_NUMERIC", f"{label}: status parameter {p.name} is {p.type_up}; define a success rule", p.idx)
                if not numeric:
                    add("WARN", "STATUS_ANCHORED_TYPE", f"{label}: status {p.name} uses %TYPE; assumed numeric", model.line(p.idx))
                ok = st["numeric_success_expression"].format(v=t[p.idx].value)
            status_name = p.name
        else:
            ok = st["no_status_expression"]
            status_name = None
            add("WARN", "STATUS_UNGATED",
                f"{label}: no status OUT parameter found; files are released on every normal exit", model.line(r.start))
        fail_ok = st["exception_exit_expression"]

        # ---- open handles at exit
        has_close = any(m in self.closes for m, _ in span_ops)
        pol = self.r["open_handles_at_end"]["units_with_fclose" if has_close else "units_without_fclose"]
        submit_open = pol == "submit"
        if not has_close and (self.direction == "download" or self.unit_writes(model, span_ops)):
            add("WARN", "IMPLICIT_CLOSE",
                f"{label} never calls FCLOSE. Legacy files were closed at session end; open files are submitted at normal exit",
                model.line(r.start))
        if r.kind == "FUNCTION":
            add("WARN", "FUNCTION_UNIT",
                f"{label} is a function: END_UNIT runs before each RETURN expression is evaluated", model.line(r.start))

        def end_call(expr, submit=False):
            extra = ", p_submit_open => TRUE" if submit else ""
            return f"{self.pkg}.end_unit({fr}, {expr}{extra});"

        normal = end_call(ok, submit_open)
        failure = end_call(fail_ok)

        # ---- metadata for BEGIN_UNIT
        ins = {p.name: p for p in r.params if p.modes == {"IN"}}
        binds = [("p_unit_name", f"'{label}'")]
        if label.upper() in self.interface_overrides:
            binds.append(("p_interface_code", f"'{self.interface_overrides[label.upper()]}'"))
        for k, v in (extra_binds or []):
            binds.append((k, v))
        bound = {}
        md = self.r.get("metadata", {})
        fmt = md.get("date_format", "YYYY-MM-DD")

        def as_text(p):
            v = t[p.idx].value
            if re.fullmatch(r"(DATE|TIMESTAMP.*)", p.type_up.strip()):
                return f"TO_CHAR({v}, '{fmt}')"
            return v

        hit = next((a for a in md.get("business_date_aliases", []) if a.upper() in ins), None)
        if hit:
            bound["p_business_date"] = as_text(ins[hit.upper()])
            binds.append(("p_business_date", bound["p_business_date"]))
        ctx = [ins[n.upper()] for n in md.get("context_parameters", []) if n.upper() in ins]
        if ctx:
            parts = [f"'{t[p.idx].value.upper()}=' || {as_text(p)}" for p in ctx]
            bound["p_context"] = " || ';' || ".join(parts)
            binds.append(("p_context", bound["p_context"]))
        w = max(len(k) for k, _ in binds)

        # ---- declaration right after IS/AS
        is_tok = t[r.is_at]
        base = self.indent(text, is_tok.start)
        self.insert_after_line(edits, text, is_tok, f"{base}  {fr} PLS_INTEGER;  -- ORAAS: file frame (generated)", nl)

        # ---- BEGIN_UNIT as first statement
        bt = t[r.begin]
        bi = self.indent(text, bt.start) + "  "
        lines = [f"{bi}{fr} := {self.pkg}.begin_unit("]
        for n, (k, v) in enumerate(binds):
            lines.append(f"{bi}    {k.ljust(w)} => {v}{',' if n < len(binds) - 1 else ');  -- ORAAS (generated)'}")
        self.insert_after_line(edits, text, bt, nl.join(lines), nl)

        body = r.body
        inserted = {"return": 0, "raise": 0, "handlers": 0}

        # ---- RETURN statements anywhere in the main body
        for i in range(r.begin + 1, body.end):
            if model.kw(i, "RETURN") and model.stmt_start(i) and not model.in_excluded(i):
                self.insert_before_stmt(edits, text, t[i], normal, nl)
                inserted["return"] += 1

        # ---- end of main body
        anchor = body.exception if body.exception >= 0 else body.end
        self.insert_line_before(edits, text, t[anchor], normal, nl, extra_indent="  ")

        # ---- main exception handlers
        has_others = False
        if body.exception >= 0:
            hs = body.handlers
            for n, (w_i, th) in enumerate(hs):
                h_end = hs[n + 1][0] if n + 1 < len(hs) else body.end
                cond = [U[x] for x in range(w_i + 1, th)]
                if cond == ["OTHERS"] or "OTHERS" in cond:
                    has_others = True
                ends_with_raise = False
                for i in range(th + 1, h_end):
                    if model.in_excluded(i):
                        continue
                    is_raise = model.kw(i, "RAISE") and model.stmt_start(i)
                    is_rae = model.kw(i, "RAISE_APPLICATION_ERROR") and (
                        model.stmt_start(i) or (U[i - 1] == "." and model.kw(i - 2, "DBMS_STANDARD")
                                                and model.stmt_start(i - 2)))
                    if (is_raise or is_rae) and not model.caught_inside(i, th):
                        anchor_i = i - 2 if U[i - 1] == "." else i
                        self.insert_before_stmt(edits, text, t[anchor_i], failure, nl)
                        inserted["raise"] += 1
                        if model.to_semicolon(i) == h_end - 1:
                            ends_with_raise = True     # handler cannot fall through
                first = t[th + 1] if th + 1 < h_end else None
                h_ind = (self.indent(text, first.start) if first is not None and self.first_on_line(text, first)
                         else self.indent(text, t[w_i].start) + "    ")
                if not ends_with_raise:
                    self.insert_line_before(edits, text, t[h_end], normal, nl, indent=h_ind)
                    inserted["handlers"] += 1
            if not has_others:
                wi = self.indent(text, t[hs[0][0]].start) if hs else self.indent(text, t[body.exception].start) + "  "
                block = nl.join([f"{wi}WHEN OTHERS THEN  -- ORAAS (generated): every exit must end the frame",
                                 f"{wi}  {failure}", f"{wi}  RAISE;"])
                self.insert_raw_line_before(edits, text, t[body.end], block, nl)
        else:
            ei = self.indent(text, t[body.end].start)
            block = nl.join([f"{ei}EXCEPTION  -- ORAAS (generated): every exit must end the frame",
                             f"{ei}  WHEN OTHERS THEN", f"{ei}    {failure}", f"{ei}    RAISE;"])
            self.insert_raw_line_before(edits, text, t[body.end], block, nl)

        return {"unit": label, "frame": True, "status_parameter": status_name, "ok_expression": ok,
                "submit_open_handles": submit_open, "begin_unit_bindings": bound,
                "end_unit_calls": {"end_of_body": 1, **inserted,
                                   "added_when_others": not has_others}}

    # -------------------------------------------------- text placement
    @staticmethod
    def line_start(text, pos):
        return text.rfind("\n", 0, pos) + 1

    @staticmethod
    def line_end(text, pos):
        e = text.find("\n", pos)
        e = len(text) if e < 0 else e
        return e - 1 if e > 0 and text[e - 1] == "\r" else e

    def indent(self, text, pos):
        ls = self.line_start(text, pos)
        return re.match(r"[ \t]*", text[ls:]).group(0)

    def first_on_line(self, text, tok):
        return text[self.line_start(text, tok.start):tok.start].strip() == ""

    def insert_after_line(self, edits, text, tok, block, nl):
        """Inserts block on new line(s) after tok. Keeps a trailing -- comment on tok's line."""
        le = self.line_end(text, tok.end)
        rest = text[tok.end:le].strip()
        if rest == "" or rest.startswith("--"):
            edits.insert(le, nl + block)
        else:
            edits.insert(tok.end, nl + block + nl + self.indent(text, tok.start) + "  ")

    def insert_before_stmt(self, edits, text, tok, stmt, nl):
        if self.first_on_line(text, tok):
            edits.insert(self.line_start(text, tok.start), self.indent(text, tok.start) + stmt + nl)
        else:
            edits.insert(tok.start, stmt + " ")

    def insert_line_before(self, edits, text, tok, stmt, nl, indent=None, extra_indent=""):
        ind = indent if indent is not None else self.indent(text, tok.start) + extra_indent
        if self.first_on_line(text, tok):
            edits.insert(self.line_start(text, tok.start), ind + stmt + nl)
        else:
            edits.insert(tok.start, nl + ind + stmt + nl + self.indent(text, tok.start))

    def insert_raw_line_before(self, edits, text, tok, block, nl):
        if self.first_on_line(text, tok):
            edits.insert(self.line_start(text, tok.start), block + nl)
        else:
            edits.insert(tok.start, nl + block + nl)

    # ------------------------------------------------------------ verify
    def verify(self, new_text, old_model):
        try:
            src = Source(new_text)
            m = Model(src)
        except ReviewRequired as e:
            raise ReviewRequired("SELF_CHECK_FAILED", f"Generated source does not re-parse: {e.message}", e.line)
        left = [i for i, x in enumerate(src.toks) if x.kind == "id" and x.up == "UTL_FILE"]
        if left:
            raise ReviewRequired("SELF_CHECK_FAILED", "Active UTL_FILE reference left after conversion", m.line(left[0]))
        if [(u.kind, u.name) for u in m.units] != [(u.kind, u.name) for u in old_model.units]:
            raise ReviewRequired("SELF_CHECK_FAILED", "Program unit names/kinds changed during conversion")


# =============================================================================
# Batch driver
# =============================================================================
def read_source(path):
    raw = path.read_bytes()
    if raw.startswith(b"PK\x03\x04") or b"\x00" in raw[:4096]:
        raise ReviewRequired("NOT_TEXT", "Input is not a plain-text source (Word/zip/binary file). "
                             "Export the unit from the database as text")
    bom = raw.startswith(b"\xef\xbb\xbf")
    try:
        return raw[3:].decode("utf-8") if bom else raw.decode("utf-8"), "utf-8", bom
    except UnicodeDecodeError:
        return raw.decode("cp1252"), "cp1252", False


def unified_diff(a, b, fromfile, tofile, n=3):
    """difflib.unified_diff without the autojunk heuristic (keeps frequent lines such as RETURN; aligned)."""
    out = [f"--- {fromfile}\n", f"+++ {tofile}\n"]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    for group in sm.get_grouped_opcodes(n):
        i1, i2, j1, j2 = group[0][1], group[-1][2], group[0][3], group[-1][4]
        out.append(f"@@ -{i1 + 1},{i2 - i1} +{j1 + 1},{j2 - j1} @@\n")
        for tag, a1, a2, b1, b2 in group:
            if tag == "equal":
                out += [" " + x for x in a[a1:a2]]
                continue
            out += ["-" + x for x in a[a1:a2]]
            out += ["+" + x for x in b[b1:b2]]
    return "".join(x if x.endswith("\n") else x + "\n" for x in out)


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main(argv=None):
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description="ORAAS UTL_FILE batch converter (UTL_FILE -> ORAAS_UTL)")
    ap.add_argument("input_dir", type=Path, help="Folder with the legacy sources")
    ap.add_argument("--direction", choices=["download", "upload"], default="download",
                    help="download: units that write files; upload: units that read files (default download)")
    ap.add_argument("--rules", type=Path, help="Recipe JSON (default: ../config/<direction>_rules.json)")
    ap.add_argument("--output-dir", type=Path, help="Default: <parent of input>/<folders.output in the rules>")
    ap.add_argument("--diff-dir", type=Path, help="Default: <parent of input>/<folders.diff in the rules>")
    ap.add_argument("--report-dir", type=Path, help="Default: <parent of input>/<folders.reports in the rules>")
    ap.add_argument("--overwrite", action="store_true", help="Replace outputs from an earlier run")
    a = ap.parse_args(argv)

    rules_path = a.rules or here.parent / "config" / f"{a.direction}_rules.json"
    if not a.input_dir.is_dir():
        print(f"Input folder not found: {a.input_dir}")
        return 2
    rules = json.loads(rules_path.read_text(encoding="utf-8"))
    if rules.get("schema_version") != 1 or rules.get("direction") not in ("download", "upload"):
        print(f"{rules_path} is not a schema_version 1 download/upload recipe")
        return 2
    folders = rules.get("folders", {})
    base = a.input_dir.resolve().parent
    out_dir = a.output_dir or base / folders.get("output", "converted")
    diff_dir = a.diff_dir or base / folders.get("diff", "diff")
    rep_dir = a.report_dir or base / folders.get("reports", "reports")
    for d in (out_dir, diff_dir, rep_dir):
        d.mkdir(parents=True, exist_ok=True)
    conv = Converter(rules)
    exts = {e.lower() for e in rules["files"]["extensions"]}
    skip, suffix = rules["files"]["skip_suffix"].upper(), rules["files"]["output_suffix"]

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    files = sorted(p for p in a.input_dir.rglob("*")
                   if p.is_file() and p.suffix.lower() in exts and not p.stem.upper().endswith(skip))
    rows, objects = [], {}
    log_lines = [f"ORAAS UTL_FILE converter v{TOOL_VERSION} run {stamp}", f"input={a.input_dir.resolve()}",
                 f"rules={rules_path.resolve()}", f"files={len(files)}", ""]

    for path in files:
        rel = path.relative_to(a.input_dir)
        out_path = out_dir / rel.parent / f"{path.stem}{suffix}{path.suffix}"
        diff_path = diff_dir / rel.parent / f"{path.stem}{path.suffix}.diff"
        rep_path = rep_dir / rel.parent / f"{path.stem}{path.suffix}.report.json"
        for p in (out_path, diff_path, rep_path):
            p.parent.mkdir(parents=True, exist_ok=True)
        report = {"tool_version": TOOL_VERSION, "run": stamp, "input": str(rel)}
        written = ""
        try:
            raw = path.read_bytes()
            report["input_sha256"] = sha(raw)
            text, enc, bom = read_source(path)
            report["encoding"] = enc + (" (BOM)" if bom else "")
            new_text, rep = conv.convert(text)
            if enc != "utf-8":
                rep["findings"].append(Finding("WARN", "ENCODING_FALLBACK",
                                               "Source is not valid UTF-8; read and written as cp1252"))
            report.update(rep)
            if new_text is not None:
                if not a.overwrite and out_path.exists():
                    raise ReviewRequired("OUTPUT_EXISTS", f"{out_path.name} exists; rerun with --overwrite")
                data = (b"\xef\xbb\xbf" if bom else b"") + new_text.encode(enc)
                out_path.write_bytes(data)
                report["output"] = str(out_path)
                report["output_sha256"] = sha(data)
                diff = unified_diff(text.splitlines(True), new_text.splitlines(True), str(rel), out_path.name)
                diff_path.write_text(diff, encoding="utf-8", newline="")
                report["diff"] = str(diff_path)
                report["oracle_compiled"] = False
                report["golden_compared"] = False
                written = str(out_path)
        except ReviewRequired as e:
            report.setdefault("findings", []).append(Finding("BLOCK", e.code, e.message, e.line))
            report["status"] = "UPLOAD_SCOPE" if e.code == "UPLOAD_SCOPE" else "REVIEW_REQUIRED"
            report["blocker"] = {"code": e.code, "message": e.message, "line": e.line}
            if diff_path.exists() and a.overwrite:
                diff_path.unlink()
        except Exception as e:      # tool defect: keep going with the next file
            report["status"] = "TOOL_ERROR"
            report["blocker"] = {"code": "TOOL_ERROR", "message": repr(e)}
            report["traceback"] = traceback.format_exc()
        findings = [f.as_dict() if isinstance(f, Finding) else f for f in report.get("findings", [])]
        report["findings"] = findings
        rep_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

        for o in report.get("objects", []):
            objects.setdefault(o, []).append(str(rel))
        warn_codes = sorted({f["code"] for f in findings if f["level"] == "WARN"})
        rows.append({
            "file": str(rel), "status": report["status"],
            "objects": "; ".join(report.get("objects", [])),
            "blocker_code": (report.get("blocker") or {}).get("code", ""),
            "blocker_line": (report.get("blocker") or {}).get("line", "") or "",
            "blocker_message": (report.get("blocker") or {}).get("message", ""),
            "warnings": "; ".join(warn_codes),
            "operations": "; ".join(f"{k}x{len(v)}" for k, v in sorted(report.get("operations", {}).items())),
            "frames": sum(1 for u in report.get("units", []) if u.get("frame")),
            "output": written,
        })
        log_lines.append(f"{report['status']:<24} {rel}"
                         + (f"  [{rows[-1]['blocker_code']} line {rows[-1]['blocker_line']}] {rows[-1]['blocker_message']}"
                            if rows[-1]["blocker_code"] else "")
                         + (f"  warnings: {rows[-1]['warnings']}" if rows[-1]["warnings"] else ""))

    dups = {o: fs for o, fs in objects.items() if len(fs) > 1}
    if dups:
        log_lines += ["", "DUPLICATE OBJECTS (same unit in several files; only one may be deployed):"]
        log_lines += [f"  {o}: {', '.join(fs)}" for o, fs in sorted(dups.items())]

    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    log_lines += ["", "TOTALS: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))]

    csv_path = rep_dir / f"batch_summary_{stamp}.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else ["file"])
        wr.writeheader()
        wr.writerows(rows)
    (rep_dir / f"batch_summary_{stamp}.json").write_text(
        json.dumps({"tool_version": TOOL_VERSION, "run": stamp, "totals": counts,
                    "duplicate_objects": dups, "files": rows}, indent=2) + "\n", encoding="utf-8")
    (rep_dir / f"batch_{stamp}.log").write_text("\n".join(log_lines) + "\n", encoding="utf-8")
    print("\n".join(log_lines))
    print(f"\nSummary: {csv_path}")
    return 1 if counts.get("TOOL_ERROR") else 0


if __name__ == "__main__":
    sys.exit(main())
