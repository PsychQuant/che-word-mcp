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

Exit code is 0 iff zero crashes and zero timeouts were observed. A summary
line (`probes=N crashes=N timeouts=N secs=N`) is always printed; a per-probe
TSV of every result (not just failures) is written to
`<workdir>/fuzz_results.tsv` for later inspection.

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
        if "integer" in types:
            for v in INT_VALUES:
                probes.append((t, {k: v}, f"{k}={v}"))
        elif "number" in types:
            for v in NUM_VALUES:
                probes.append((t, {k: v}, f"{k}={v}"))

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
]

counter = [0]


def run(probe):
    t, over, label = probe
    counter[0] += 1
    rd = os.path.join(WORK, "runs", f"{counter[0]:05d}")
    os.makedirs(rd, exist_ok=True)
    doc = os.path.join(rd, "doc.docx")
    shutil.copy(FIX, doc)
    s = Session()
    s.call("open_document", {"doc_id": "d", "path": doc})
    args = base_args(t, rd, doc)
    args.update(over)
    r = s.call(t["name"], args, timeout=30)
    code, err = s.close()
    shutil.rmtree(rd, ignore_errors=True)
    fatal = next((l for l in err.splitlines() if "Fatal error" in l), "")
    if r is None:
        return ("CRASH", t["name"], label, fatal[:160] or f"exit={code}")
    if r == "TIMEOUT":
        return ("TIMEOUT", t["name"], label, "")
    return ("ok", t["name"], label, text(r)[:120])


def run_seq(item):
    label, steps = item
    counter[0] += 1
    rd = os.path.join(WORK, "runs", f"s{counter[0]:05d}")
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
        outs.append(text(r)[:80])
    s.close()
    shutil.rmtree(rd, ignore_errors=True)
    return ("ok", "SEQ", label, " | ".join(outs))


t0 = time.time()
with ThreadPoolExecutor(max_workers=int(os.environ.get("FUZZ_J", "8"))) as ex:
    results = list(ex.map(run, probes)) + list(ex.map(run_seq, seqs))
bad = [r for r in results if r[0] != "ok"]
crashes = sum(1 for r in bad if r[0] == "CRASH")
timeouts = sum(1 for r in bad if r[0] == "TIMEOUT")
print(f"probes={len(results)} crashes={crashes} timeouts={timeouts} secs={time.time() - t0:.0f}")
for r in bad:
    print(" | ".join(r))
with open(os.path.join(WORK, "fuzz_results.tsv"), "w") as f:
    for r in results:
        f.write("\t".join(r) + "\n")

sys.exit(0 if (crashes == 0 and timeouts == 0) else 1)
