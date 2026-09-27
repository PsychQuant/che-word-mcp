#!/usr/bin/env python3
"""fuzz-coverage-judgment.py — unit test for `parameter_reached()` in
`scripts/fuzz-extreme-params.py` (PsychQuant/che-word-mcp#239).

`fuzz-extreme-params.py` is a procedural script (no `if __name__ ==
"__main__":` guard — it spawns real subprocesses against a real binary
starting at import time), so it cannot be `import`ed by a test without
running the whole fuzzer. Instead this extracts just the `parameter_reached`
function's source via `ast` and `exec`s it in an isolated namespace — the
same "test a script without importing it" pattern
`scripts/tests/release-source-stability.sh` uses for `release.sh` (a
subprocess harness there; an AST-extraction harness here, because the unit
under test is a single pure function rather than a whole CLI invocation).

Usage:
    python3 scripts/tests/fuzz-coverage-judgment.py

Exits 0 with "all N cases passed" on success, non-zero with a diff of the
failing case(s) otherwise.
"""
import ast
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT_PATH = os.path.join(ROOT, "scripts", "fuzz-extreme-params.py")


def load_parameter_reached():
    with open(SCRIPT_PATH, "r", encoding="utf-8") as f:
        source = f.read()
    tree = ast.parse(source, filename=SCRIPT_PATH)
    func_node = next(
        (n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "parameter_reached"),
        None,
    )
    if func_node is None:
        print(f"FAIL: parameter_reached() not found in {SCRIPT_PATH} — "
              "was it renamed or inlined back into the loop?")
        sys.exit(1)
    func_source = ast.get_source_segment(source, func_node)
    namespace = {"re": __import__("re")}
    exec(compile(func_source, SCRIPT_PATH, "exec"), namespace)
    return namespace["parameter_reached"]


parameter_reached = load_parameter_reached()

# (key, val, out, expected, description)
CASES = [
    # ---- #239's three named false-positive shapes: a bare successful
    # response with NEITHER the key nor the value present must now be
    # judged UNREACHED — this is the regression the whole fix targets.
    ("abstract_num_id", "1", "OK  Started new list", False,
     "start_new_list shape: OK response says nothing about the target key/value"),
    ("style_id", "9223372036854775807", "OK  ", False,
     "set_table_style shape: tool did nothing, replied bare OK"),
    ("enable", "-1", "OK  Set line numbers", False,
     "set_line_numbers shape: branch never entered, OK doesn't mention enable"),
    # ---- Genuine positive evidence must still be judged REACHED.
    ("width", "9223372036854775807", "OK  width=9223372036854775807 accepted", True,
     "response echoes the exact key=value"),
    ("width", "9223372036854775807", "ERR Invalid parameter 'width': out of range", True,
     "error names the key"),
    ("paragraph_index", "-1", "ERR Invalid paragraph index: -1", True,
     "index-shape error regex match"),
    ("comment_id", "-1", "ERR comment with id -1 not found", True,
     "id-not-found shape error regex match"),
    ("rows", "-1", "ERR rows must be positive, got -1", True,
     "error echoes the bare value"),
    # ---- A value appearing only by coincidence in an unrelated OK message
    # is intentionally still counted as reached (the function's contract is
    # "key or value appears", not "and nothing else does") — not a
    # regression target, just documenting the known boundary.
    ("level", "1", "OK  levels[1] configured", True,
     "value 1 appears in an unrelated-looking OK message — documented boundary, not a #239 target"),
]

failures = []
for key, val, out, expected, desc in CASES:
    actual = parameter_reached(key, val, out)
    if actual != expected:
        failures.append(
            f"  key={key!r} val={val!r} out={out!r}\n"
            f"    expected {expected}, got {actual} — {desc}"
        )

if failures:
    print(f"FAIL: {len(failures)}/{len(CASES)} case(s) failed:")
    for f in failures:
        print(f)
    sys.exit(1)

print(f"all {len(CASES)} cases passed")
sys.exit(0)
