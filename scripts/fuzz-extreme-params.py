#!/usr/bin/env python3
"""fuzz-extreme-params.py — crash fuzzer for che-word-mcp (PsychQuant/che-word-mcp#234, R8).

For every integer/number parameter declared in `tools/list`'s schema (plus a
hand-written list of nested/undocumented integer fields and a few
multi-step sequences), sends extreme values — `Int.max`, `Int.min`, `2^62`,
`2^31`, `-1` for integers; `1e300`, `-1e300`, `Int.max`, `-1` for numbers —
to the REAL compiled binary over stdio (MCP JSON-RPC), one fresh server
process per probe, against an opened fixture document. Reports every probe
where the server process died (no response / non-zero unexpected exit) or
hung past its timeout.

Why a black-box process-level fuzzer instead of just more unit tests: the
crashes this targets are Swift traps (`Int` overflow, out-of-range
`Range(_:_:)`, `String.Index(offsetBy:)`, etc.) — these are NOT catchable
`WordError`s, they kill the entire process, including an XCTest run that
tried to exercise the same code path in-process. A subprocess-per-probe
harness is the only way to find these without one crash taking the whole
test run down with it.

History: adapted from an independent reviewer's (`rev232b`) ad-hoc probe
scripts, which found 58 crashes on che-word-mcp HEAD `50d0e92` (proving the
approach works) and 5 more after #234's first round of manual-audit fixes
(`c1aabdd`) — all 5 were within #234's own broadened audit criterion ("any
user-input arithmetic that feeds an `Int` conversion") but had been missed
by grep-based manual auditing. R8 fixed those 5 and brought this script
into the repo so the NEXT round doesn't have to re-derive it from scratch,
and so "the fuzzer finds zero crashes" can be a mechanical completion
condition instead of relying on manual audit coverage.

Usage:
    python3 scripts/fuzz-extreme-params.py <path-to-CheWordMCP-binary> <scratch-workdir>

    # e.g. against a debug build from the repo root:
    python3 scripts/fuzz-extreme-params.py .build/debug/CheWordMCP /tmp/fuzz-workdir

Exit code is 0 only when ALL of these hold (R9):
  - no probe crashed or hung, including the save that follows every probe
    (`CRASH@save` / `TIMEOUT@save`; disable the save with FUZZ_NO_SAVE=1);
  - every probe labelled "(must reject)" was actually rejected;
  - every `(mem)` sequence left the server under FUZZ_MEM_LIMIT_MB (default
    1024) resident — "legal but exhausts the host" is a failure too;
  - at least FUZZ_MIN_COVERAGE (default 0.97) of the schema's integer/number
    parameters were REACHED: a probe stopped by an unrelated precondition
    proves nothing about its target, so a fuzzer whose probes stop reaching
    their targets must fail rather than keep reporting zero crashes.
A summary line and a coverage line are always printed, with the unreached
parameters listed; a per-probe TSV of every result is written to
`<workdir>/fuzz_results.tsv`.

R9 history: the R8 version of this script dropped the original reviewer
script's per-tool overrides (`OV`), preconditions (`PRE`) and save-after-probe,
and 60 of 245 parameters never reached their target — the "zero crashes" it
reported was measured on a quarter less surface than it claimed. Those are
restored, and the coverage check exists so that cannot happen silently again.

When to run this: before any release that touches integer/number parameter
handling in Server.swift, and any time a new tool or a new integer/number
parameter is added to an existing tool — this script has no way to know
which parameters are "new" and always fuzzes everything currently declared
in `tools/list`, so re-running it is the mechanical way to check nothing
regressed. It is NOT wired into `swift test` by default (spawning ~1500
subprocesses takes on the order of a minute and needs a real compiled
binary, not just a test target) — see `FuzzExtremeParamsGateTests.swift`
for the `RUN_FUZZ=1`-gated `swift test` entry point that shells out to this
script, for CI/release use.
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import select
import base64
import zlib
from concurrent.futures import ThreadPoolExecutor

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

BIN, WORK = sys.argv[1], sys.argv[2]
os.makedirs(WORK, exist_ok=True)


def real_png(w, h):
    """A minimal but genuinely valid PNG of the given pixel size — real
    IHDR/IDAT/IEND chunks with correct CRC32s, not hand-faked bytes, so
    `ImageDimensions.detect(path:)` reads a real aspect ratio."""
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


PNG = os.path.join(WORK, "img.png")
open(PNG, "wb").write(real_png(4, 2))
PNG_B64 = base64.b64encode(open(PNG, "rb").read()).decode()


class Session:
    def __init__(self):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.rid = 100
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "fuzz-extreme-params", "version": "0"}}})
        self.recv(1)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode())
        self.p.stdin.flush()

    def recv(self, want, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([self.p.stdout], [], [], 0.3)
            if r:
                line = self.p.stdout.readline()
                if not line:
                    return None
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                if m.get("id") == want:
                    return m
            elif self.p.poll() is not None:
                return None
        return "TIMEOUT"

    def call(self, name, args, timeout=20):
        self.rid += 1
        try:
            self.send({"jsonrpc": "2.0", "id": self.rid, "method": "tools/call", "params": {"name": name, "arguments": args}})
        except (BrokenPipeError, OSError):
            return None
        return self.recv(self.rid, timeout)

    def raw(self, method, params=None):
        self.rid += 1
        self.send({"jsonrpc": "2.0", "id": self.rid, "method": method, "params": params or {}})
        return self.recv(self.rid)

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(5)
            except Exception:
                self.p.kill()
        return self.p.returncode, self.p.stderr.read().decode(errors="replace")


def text(resp):
    if not isinstance(resp, dict):
        return str(resp)
    r = resp.get("result") or {}
    c = r.get("content") or [{}]
    return ("ERR " if r.get("isError") else "OK  ") + (c[0].get("text", "") if c else "")


# ---- fixture: a document exercising every major element type, so probes
# against read/consume tools (not just insert tools) have something to bite
# on ----
FIX = os.path.join(WORK, "fixture.docx")
if not os.path.exists(FIX):
    s = Session()
    steps = [
        ("create_document", {"doc_id": "f"}),
        ("insert_paragraph", {"doc_id": "f", "text": "Anchor paragraph with bold words"}),
        ("insert_paragraph", {"doc_id": "f", "text": "Second paragraph"}),
        ("insert_paragraph", {"doc_id": "f", "text": "Third paragraph"}),
        ("format_text", {"doc_id": "f", "paragraph_index": 0, "bold": True}),
        ("create_numbering_definition", {"doc_id": "f", "levels": [{"ilvl": 0, "num_format": "decimal", "lvl_text": "%1."}]}),
        ("insert_image_from_path", {"doc_id": "f", "path": PNG, "width": 40, "height": 20}),
        ("insert_table", {"doc_id": "f", "rows": 2, "cols": 2}),
        ("insert_comment", {"doc_id": "f", "paragraph_index": 0, "text": "c", "author": "A"}),
        ("insert_footnote", {"doc_id": "f", "paragraph_index": 1, "text": "fn"}),
        ("insert_endnote", {"doc_id": "f", "paragraph_index": 1, "text": "en"}),
        ("insert_equation", {"doc_id": "f", "latex": "x^2", "paragraph_index": 2}),
        ("insert_bookmark", {"doc_id": "f", "paragraph_index": 0, "name": "bm1"}),
        ("insert_caption", {"doc_id": "f", "label": "Figure", "caption_text": "cap", "paragraph_index": 0}),
        ("insert_content_control", {"doc_id": "f", "paragraph_index": 1, "tag": "t1", "text": "cc", "type": "richText"}),
        ("save_document", {"doc_id": "f", "path": FIX, "allow_orphan_images": True}),
    ]
    for n, a in steps:
        print("fixture:", n, text(s.call(n, a))[:120])
    s.close()

# ---- schema ----
s = Session()
tools = s.raw("tools/list")["result"]["tools"]
s.close()
by = {t["name"]: t for t in tools}

# ---- R9 (review `rev232c` M-1): per-tool overrides and preconditions ----
# Ported verbatim from the original reviewer script (`fuzz_ints2.py`). Without
# them, 60 of 245 top-level integer/number parameters never reached their own
# validation — the probe was stopped first by an unrelated precondition
# (`Missing required parameter: path`, `track_changes_not_enabled`, a missing
# second document, a list level with no numbering, …), so the "zero crashes"
# result said nothing about those parameters. `OV` supplies correct required
# values; `PRE` runs setup calls first. `@PNG@`/`@DOC@`/`@DOC2@` are replaced
# per probe. The coverage check at the end fails the run if too many
# parameters again go unreached.
OV = {
 "add_comment_reply": {"comment_id": 1, "text": "r"},
 "reply_to_comment": {"parent_comment_id": 1, "text": "r"},
 "compare_documents": {"doc_id_a": "d", "doc_id_b": "e"},
 "delete_text_as_revision": {"paragraph_index": 0, "start": 0, "end": 3},
 "insert_text_as_revision": {"paragraph_index": 0, "position": 0, "text": "z"},
 "move_text_as_revision": {"from_paragraph_index": 0, "from_start": 0, "from_end": 3, "to_paragraph_index": 1, "to_position": 0},
 "insert_content_control": {"paragraph_index": 0, "type": "richText", "tag": "t9"},
 "insert_cross_reference": {"paragraph_index": 0, "reference_type": "bookmark", "reference_target": "bm1"},
 "insert_dropdown": {"paragraph_index": 0, "name": "dd", "options": ["a", "b"]},
 "insert_equation": {"latex": "x"},
 "insert_floating_image": {"path": "@PNG@", "base64": "x", "file_name": "a.png", "width": 100000, "height": 100000},
 "insert_symbol": {"paragraph_index": 0, "char": "F020"},
 "insert_table_of_figures": {"paragraph_index": 0, "caption_label": "Figure"},
 "link_section_header_to_previous": {"section_index": 0, "type": "default"},
 "unlink_section_header_from_previous": {"section_index": 0, "type": "default"},
 "merge_cells": {"table_index": 0, "direction": "horizontal", "row": 0, "col": 0, "end_col": 1},
 "set_cell_vertical_alignment": {"table_index": 0, "row": 0, "col": 0, "alignment": "top"},
 "set_image_style": {"image_id": "rId5"},
 "update_image": {"image_id": "rId5"},
 "set_list_level": {"paragraph_index": 0, "level": 0},
 "set_page_borders": {"style": "single"},
 "set_page_number_format": {"section_index": 0, "format": "decimal"},
 "set_section_break_type": {"section_index": 0, "type": "nextPage"},
 "set_section_vertical_alignment": {"section_index": 0, "alignment": "top"},
 "set_table_alignment": {"table_index": 0, "alignment": "left"},
 "set_table_conditional_style": {"table_index": 0, "type": "firstRow", "properties": {"bold": True}},
 "set_table_layout": {"table_index": 0, "type": "fixed"},
 "set_text_direction": {"direction": "lrTb", "paragraph_index": 0},
 "set_text_effect": {"paragraph_index": 0, "effect": "shimmer"},
 "splice_omath_from_source": {"source_paragraph_index": 2, "target_paragraph_index": 0, "position": "atEnd", "source_path": "@DOC@"},
 "splice_paragraph_omath_from_source": {"source_paragraph_index": 2, "target_paragraph_index": 0, "source_path": "@DOC@"},
 "update_caption": {"index": 0, "new_caption_text": "n"},
 "insert_caption": {"after_text": "Anchor"},
 "set_columns": {"columns": 2},
 "set_page_size": {"size": "A4"},
 "open_document": {"doc_id": "z", "path": "@DOC@"},
}
PRE = {
 "delete_text_as_revision": [("enable_track_changes", {"doc_id": "d"})],
 "insert_text_as_revision": [("enable_track_changes", {"doc_id": "d"})],
 "move_text_as_revision": [("enable_track_changes", {"doc_id": "d"})],
 "compare_documents": [("open_document", {"doc_id": "e", "path": "@DOC2@"})],
 "set_list_level": [("assign_numbering_to_paragraph", {"doc_id": "d", "paragraph_index": 0, "num_id": 1, "level": 0})],
}


def base_args(tool, run_dir, doc):
    """Fills every REQUIRED (non-target) parameter with a plausible value so
    the probe actually reaches the target parameter's own validation,
    instead of being preempted by an unrelated `missingParameter`."""
    name = tool["name"]
    sch = tool.get("inputSchema", {})
    props = sch.get("properties", {})
    req = set(sch.get("required", []))
    a = {}
    if "doc_id" in props:
        a["doc_id"] = "d"
    if "source_path" in props and ("source_path" in req or "doc_id" not in props):
        a["source_path"] = doc
    for k in req:
        if k in a:
            continue
        p = props.get(k, {})
        t = p.get("type")
        if isinstance(t, list):
            t = t[0]
        if "enum" in p:
            a[k] = p["enum"][0]
            continue
        if t == "integer":
            a[k] = 1 if re.search(r"rows|cols|count|level|width|height|size|page|num_id|abstract", k) else 0
        elif t == "number":
            a[k] = 1.0
        elif t == "boolean":
            a[k] = False
        elif t == "array":
            a[k] = {"queries": ["Anchor"], "replacements": [{"find": "Anchor", "replace": "Anchor"}],
                     "levels": [{"ilvl": 0, "num_format": "decimal", "lvl_text": "%1."}],
                     "comment_ids": [0], "latent_styles": [{"name": "Normal"}], "items": ["a"],
                     "data": [["a"]], "documents": [{"path": doc, "label": "a"}, {"path": doc, "label": "b"}],
                     "components": [{"type": "run", "text": "x"}]}.get(k, [])
        elif t == "object":
            a[k] = {"into_table_cell": {"table_index": 0, "row": 0, "col": 0}}.get(k, {})
        else:
            kl = k.lower()
            if "path" in kl:
                if "image" in kl or ("image" in name and kl == "path") or name == "insert_floating_image":
                    a[k] = PNG
                elif kl in ("source_path",) or name in ("open_document", "compare_documents"):
                    a[k] = doc
                elif "script" in kl:
                    a[k] = os.path.join(run_dir, "nope.mdocx.swift")
                else:
                    ext = ".md" if ("markdown" in name or "export" in name) else ".docx"
                    a[k] = os.path.join(run_dir, "out" + ext)
            elif kl in ("style_id", "style", "style_name", "based_on"):
                a[k] = "Normal"
            elif kl == "label":
                a[k] = "Figure"
            elif kl == "format_type":
                a[k] = "bold"
            elif kl in ("base64",):
                a[k] = PNG_B64
            elif kl == "file_name":
                a[k] = "a.png"
            elif kl == "latex":
                a[k] = "x"
            elif "url" in kl:
                a[k] = "https://example.com"
            elif "email" in kl:
                a[k] = "a@b.c"
            elif kl in ("image_id",):
                a[k] = "rId4"
            elif kl == "full_xml":
                a[k] = "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"x\"/>"
            else:
                a[k] = "Anchor"
    return a


INT_VALUES = [9223372036854775807, -9223372036854775808, 4611686018427387904, 2147483648, -1]
NUM_VALUES = [1e300, -1e300, 9223372036854775807, -1]
X = 9223372036854775807
N = -9223372036854775808

probes = []
for t in tools:
    props = t.get("inputSchema", {}).get("properties", {})
    for k, p in props.items():
        ty = p.get("type")
        types = ty if isinstance(ty, list) else [ty]
        ov = OV.get(t["name"], {})
        if "integer" in types:
            for v in INT_VALUES:
                probes.append((t, dict(ov, **{k: v}), f"{k}={v}"))
        elif "number" in types:
            for v in NUM_VALUES:
                probes.append((t, dict(ov, **{k: v}), f"{k}={v}"))

# Hand-written: nested/undocumented integer fields the schema-driven sweep
# above can't see (they're inside `array`/`object`-typed properties), plus
# a few tools whose required-parameter shapes `base_args` can't guess well
# enough to reach the target parameter on its own.
extra = [
    ("create_numbering_definition", {"levels": [{"ilvl": X, "num_format": "decimal", "lvl_text": "%1."}]}, "levels[].ilvl=Int.max"),
    ("create_numbering_definition", {"levels": [{"ilvl": 4611686018427387904, "num_format": "decimal", "lvl_text": "%1."}]}, "levels[].ilvl=2^62"),
    ("create_numbering_definition", {"levels": [{"ilvl": N, "num_format": "decimal", "lvl_text": "%1."}]}, "levels[].ilvl=Int.min"),
    ("create_numbering_definition", {"levels": [{"ilvl": -1, "num_format": "decimal", "lvl_text": "%1."}]}, "levels[].ilvl=-1"),
    ("create_numbering_definition", {"levels": [{"ilvl": 0, "num_format": "decimal", "lvl_text": "%1.", "start": X}]}, "levels[].start=Int.max"),
    ("insert_toc", {"min_level": 5, "max_level": 1}, "min_level>max_level"),
    ("insert_toc", {"min_level": X, "max_level": X}, "min/max=Int.max"),
    ("insert_toc", {"min_level": N, "max_level": X}, "min=Int.min max=Int.max"),
    ("insert_toc", {"min_level": -1, "max_level": 3}, "min_level=-1"),
    ("insert_caption", {"paragraph_index": X}, "paragraph_index=Int.max alone"),
    ("insert_caption", {"paragraph_index": -1}, "paragraph_index=-1 alone"),
    ("insert_text", {"paragraph_index": 0, "position": -1, "text": "x"}, "position=-1"),
    ("insert_table", {"rows": -1, "cols": 2}, "rows=-1"),
    ("insert_table", {"rows": 0, "cols": 2}, "rows=0"),
    ("insert_table", {"rows": 2, "cols": -1}, "cols=-1"),
    ("insert_table", {"rows": 2, "cols": 0}, "cols=0"),
    ("insert_table", {"rows": X, "cols": 1}, "rows=Int.max"),
    ("insert_table", {"rows": 1, "cols": X}, "cols=Int.max"),
    ("insert_table", {"rows": 100000, "cols": 100000}, "1e5x1e5"),
    ("insert_nested_table", {"parent_table_index": 0, "row_index": 0, "col_index": 0, "rows": -1, "cols": 1}, "nested rows=-1"),
    ("insert_nested_table", {"parent_table_index": 0, "row_index": 0, "col_index": 0, "rows": X, "cols": 1}, "nested rows=Int.max"),
    ("set_character_spacing", {"paragraph_index": 0, "kern": X}, "kern=Int.max"),
    ("set_character_spacing", {"paragraph_index": 0, "position": X}, "position=Int.max"),
    ("set_character_spacing", {"paragraph_index": 0, "spacing": X}, "spacing=Int.max"),
    ("set_paragraph_border", {"paragraph_index": 0, "space": X}, "space=Int.max"),
    ("insert_text_field", {"paragraph_index": 0, "name": "f", "max_length": X}, "max_length=Int.max"),
    ("set_table_conditional_style", {"table_index": 0, "type": "firstRow", "properties": {"font_size": X}}, "properties.font_size=Int.max"),
    ("set_latent_styles", {"latent_styles": [{"name": "Normal", "ui_priority": X}]}, "latent_styles[].ui_priority=Int.max"),
    ("insert_paragraph", {"text": "x", "into_table_cell": {"table_index": X, "row": X, "col": X}}, "into_table_cell=Int.max"),
    # R9: restored from the original reviewer script (dropped in R8).
    ("insert_paragraph", {"text": "x", "into_table_cell": {"table_index": N, "row": N, "col": N}}, "into_table_cell=Int.min"),
    ("insert_image_from_path", {"path": PNG, "into_table_cell": {"table_index": X, "row": 0, "col": 0}, "width": 10, "height": 10}, "img into_table_cell=Int.max"),
    ("insert_equation", {"latex": "x", "into_table_cell": {"table_index": X, "row": 0, "col": 0}}, "eq into_table_cell=Int.max"),
    ("list_comments", {"context_chars": X, "include_context": True}, "list_comments ctx Int.max"),
    ("list_comments", {"context_chars": N, "include_context": True}, "list_comments ctx Int.min"),
    ("find_unresolved_comments", {"context_chars": X}, "find_unresolved ctx Int.max"),
    ("find_inline_math_gaps", {"context_chars": X}, "math gaps ctx Int.max"),
    ("insert_nested_table", {"parent_table_index": 0, "row_index": 0, "col_index": 0, "rows": 1, "cols": 64}, "nested cols=64 (must reject)"),
    ("insert_table", {"rows": 2000, "cols": 63}, "table over cell budget (must reject)"),
    ("bulk_resolve_comments", {"comment_ids": [X, N]}, "comment_ids extremes"),
    ("insert_image_from_path", {"path": PNG, "width": X}, "img width=Int.max only"),
    ("insert_image_from_path", {"path": PNG, "height": X}, "img height=Int.max only"),
    ("insert_image_from_path", {"path": PNG, "width": 100, "height": X}, "img wide-aspect height=Int.max only"),
    ("insert_floating_image", {"path": PNG, "width": X, "height": X}, "float width/height=Int.max"),
    ("insert_floating_image", {"path": PNG, "horizontal_position": X}, "float hpos=Int.max"),
    ("update_image", {"image_id": "rId4", "width": 2863311529, "height": 2863311529}, "update_image max-ok"),
    ("search_text_with_formatting", {"query": "Anchor", "context_chars": X}, "ctx Int.max"),
    ("search_text_with_formatting", {"query": "Anchor", "context_chars": N}, "ctx Int.min"),
    ("set_page_margins", {"top": 31680, "bottom": 31680, "left": 31680, "right": 31680}, "margins max-ok"),
    ("set_page_margins", {"top": -31680, "bottom": -31680, "left": 0, "right": 0}, "margins min-ok"),
    ("set_page_margins", {"left": -100}, "margins left negative (must reject)"),
    ("insert_text", {"paragraph_index": 0, "position": -1, "text": "x"}, "insert_text position=-1 (must reject)"),
    ("set_page_margins", {"right": -100}, "margins right negative (must reject)"),
    ("set_page_size", {"width": X, "height": X}, "page size Int.max"),
    ("set_columns", {"count": X, "space": X}, "columns Int.max"),
    ("set_header_row", {"table_index": 0, "row_count": X}, "header row_count Int.max"),
]
for n, a, lab in extra:
    if n in by:
        probes.append((by[n], a, "EXTRA " + lab))
    else:
        print("no such tool:", n)

seqs = [
    ("page_size Int.max then estimate", [("set_page_size", {"width": X, "height": X}), ("estimate_paragraph_for_page", {"page": 1})]),
    ("margins max-ok then estimate", [("set_page_margins", {"top": 31680, "bottom": 31680, "left": 31680, "right": 31680}), ("estimate_paragraph_for_page", {"page": 1})]),
    ("float Int.max then save", [("insert_floating_image", {"path": PNG, "width": 10, "height": 10, "horizontal_position": X}), ("save_document", {"path": "@OUT@", "allow_orphan_images": True})]),
    # R9: restored from the original reviewer script (dropped in R8).
    ("page_size Int.min then estimate", [("set_page_size", {"width": N, "height": N}), ("estimate_paragraph_for_page", {"page": 1})]),
    ("margins min-ok then estimate", [("set_page_margins", {"top": -31680, "bottom": -31680, "left": 0, "right": 0}), ("estimate_paragraph_for_page", {"page": 1})]),
    ("columns then estimate", [("set_columns", {"count": X}), ("estimate_paragraph_for_page", {"page": 1})]),
    ("font_size max-ok then estimate", [("format_text", {"paragraph_index": 0, "font_size": 1638}), ("estimate_paragraph_for_page", {"page": 100000})]),
    # R9 (review `rev232c` H-1): the LARGEST LEGAL table, then save. A crash-only
    # fuzzer never sees "legal but exhausts the host", so this sequence also
    # bounds the server's resident memory afterwards (`(mem)` in the label).
    ("largest legal table then save (mem)", [("insert_table", {"rows": 1040, "cols": 63}), ("save_document", {"path": "@OUT@", "allow_orphan_images": True})]),
]
# Resident-memory ceiling (MB) for `(mem)` sequences. 65,536 cells measured
# about 140 MB of table state; the ceiling leaves room for the process itself.
MEM_LIMIT_MB = int(os.environ.get("FUZZ_MEM_LIMIT_MB", "1024"))

import uuid

# R9: save after every probe unless FUZZ_NO_SAVE is set. A value that is
# accepted by the tool can still crash the writer later (the original reviewer
# script ran with FUZZ_SAVE; R8 dropped it).
SAVE_AFTER_PROBE = not os.environ.get("FUZZ_NO_SAVE")


def is_error(resp):
    return isinstance(resp, dict) and bool((resp.get("result") or {}).get("isError"))


def run(probe):
    t, over, label = probe
    # A fresh directory per probe. (R8 numbered them with a shared counter
    # incremented from several threads, which could hand two probes the same
    # directory and document.)
    rd = os.path.join(WORK, "runs", uuid.uuid4().hex)
    os.makedirs(rd, exist_ok=True)
    doc = os.path.join(rd, "doc.docx")
    shutil.copy(FIX, doc)
    doc2 = os.path.join(rd, "doc2.docx")
    shutil.copy(FIX, doc2)

    def sub(v):
        return {"@PNG@": PNG, "@DOC@": doc, "@DOC2@": doc2}.get(v, v) if isinstance(v, str) else v

    s = Session()
    s.call("open_document", {"doc_id": "d", "path": doc})
    for n, a in PRE.get(t["name"], []):
        s.call(n, {k: sub(v) for k, v in a.items()})
    args = base_args(t, rd, doc)
    for k, v in over.items():
        args[k] = sub(v)
    if t["name"] == "compare_documents":
        args.pop("doc_id", None)
    r = s.call(t["name"], args, timeout=30)
    saved = ""
    if isinstance(r, dict) and SAVE_AFTER_PROBE:
        r2 = s.call("save_document", {"doc_id": "d", "path": os.path.join(rd, "saved.docx"), "allow_orphan_images": True}, timeout=30)
        if r2 is None:
            code, err = s.close()
            fatal = next((l for l in err.splitlines() if "Fatal error" in l), "")
            shutil.rmtree(rd, ignore_errors=True)
            return ("CRASH@save", t["name"], label, fatal[:160] or f"exit={code}")
        if r2 == "TIMEOUT":
            s.close()
            shutil.rmtree(rd, ignore_errors=True)
            return ("TIMEOUT@save", t["name"], label, "")
        saved = " || save: " + text(r2)[:60]
    code, err = s.close()
    shutil.rmtree(rd, ignore_errors=True)
    fatal = next((l for l in err.splitlines() if "Fatal error" in l), "")
    if r is None:
        return ("CRASH", t["name"], label, fatal[:160] or f"exit={code}")
    if r == "TIMEOUT":
        return ("TIMEOUT", t["name"], label, "")
    # R9 (review `rev232c` LOW-5): a probe labelled "(must reject)" must
    # actually be rejected, not merely survive.
    if "(must reject)" in label and not is_error(r):
        return ("NOT_REJECTED", t["name"], label, text(r)[:120])
    return ("ok", t["name"], label, (text(r)[:140] + saved).replace("\n", " ").replace("\t", " "))


def resident_mb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return int(out) / 1024 if out else None
    except Exception:
        return None


def run_seq(item):
    label, steps = item
    rd = os.path.join(WORK, "runs", "s" + uuid.uuid4().hex)
    os.makedirs(rd, exist_ok=True)
    doc = os.path.join(rd, "doc.docx")
    shutil.copy(FIX, doc)
    s = Session()
    s.call("open_document", {"doc_id": "d", "path": doc})
    outs = []
    for n, a in steps:
        a = dict(a)
        a["doc_id"] = "d"
        for k, v in list(a.items()):
            if v == "@OUT@":
                a[k] = os.path.join(rd, "o.docx")
        r = s.call(n, a, timeout=30)
        if r is None:
            code, err = s.close()
            fatal = next((l for l in err.splitlines() if "Fatal error" in l), "")
            shutil.rmtree(rd, ignore_errors=True)
            return ("CRASH", "SEQ", label + f" @ {n}", fatal[:160] or f"exit={code}")
        if r == "TIMEOUT":
            s.close()
            shutil.rmtree(rd, ignore_errors=True)
            return ("TIMEOUT", "SEQ", label + f" @ {n}", "")
        outs.append(text(r)[:80])
    mem = resident_mb(s.p.pid) if "(mem)" in label else None
    s.close()
    shutil.rmtree(rd, ignore_errors=True)
    if mem is not None and mem > MEM_LIMIT_MB:
        return ("MEMORY", "SEQ", label, f"resident {mem:.0f} MB > {MEM_LIMIT_MB} MB")
    return ("ok", "SEQ", label, " | ".join(outs) + (f" | resident {mem:.0f} MB" if mem is not None else ""))


t0 = time.time()
with ThreadPoolExecutor(max_workers=int(os.environ.get("FUZZ_J", "8"))) as ex:
    results = list(ex.map(run, probes)) + list(ex.map(run_seq, seqs))
bad = [r for r in results if r[0] != "ok"]
crashes = sum(1 for r in bad if r[0].startswith("CRASH"))
timeouts = sum(1 for r in bad if r[0].startswith("TIMEOUT"))
others = sum(1 for r in bad if not r[0].startswith(("CRASH", "TIMEOUT")))
print(f"probes={len(results)} crashes={crashes} timeouts={timeouts} other_failures={others} secs={time.time() - t0:.0f}")
for r in bad:
    print(" | ".join(r))
with open(os.path.join(WORK, "fuzz_results.tsv"), "w") as f:
    for r in results:
        f.write("\t".join(x.replace("\n", " ").replace("\t", " ") for x in r) + "\n")

# ---- R9 (review `rev232c` M-1): coverage — did each parameter's probe reach
# that parameter at all? A probe stopped by an unrelated precondition proves
# nothing about the target, and a fuzzer whose probes silently stop reaching
# their targets would keep reporting "zero crashes". A parameter counts as
# reached when any of its probes succeeded, or failed with an error that names
# the parameter / its value, or is an index/not-found error for it.
# (Same criterion as the reviewer's `coverage.py`.)
seen, reached, blockers = set(), set(), {}
for status, tool, label, out in results:
    if tool == "SEQ" or label.startswith("EXTRA") or "=" not in label:
        continue
    key, val = label.split("=", 1)
    seen.add((tool, key))
    if (out.startswith("OK") or key in out or val in out
            or re.search(r"Invalid (paragraph )?index|not found: -?\d|id -?\d+ not found|ID -?\d+|with id -?\d", out)):
        reached.add((tool, key))
    else:
        blockers.setdefault((tool, key), out[:100])
unreached = sorted(seen - reached)
ratio = (len(seen) - len(unreached)) / max(len(seen), 1)
MIN_COVERAGE = float(os.environ.get("FUZZ_MIN_COVERAGE", "0.97"))
print(f"coverage: {len(seen) - len(unreached)}/{len(seen)} parameters reached ({ratio:.1%}; minimum {MIN_COVERAGE:.0%})")
for tool, key in unreached:
    print(f"  unreached {tool}.{key} | {blockers.get((tool, key), '')}")

ok = crashes == 0 and timeouts == 0 and others == 0 and ratio >= MIN_COVERAGE
sys.exit(0 if ok else 1)
