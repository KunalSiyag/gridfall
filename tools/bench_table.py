#!/usr/bin/env python3
"""One comparison table from two FPBENCH logs (tools/tests/fp_bench.gd), for tools/bench_linux.sh.

usage: python3 tools/bench_table.py FORWARD_PLUS.log COMPATIBILITY.log

Reads the `FPBENCH {json}` rows of each log, lines up the rows both runs measured and prints, per row,
p50 and p99 frame time and fps for each renderer, the fps ratio, the slow-frame counts (frames over
33 ms, and frames that compiled pipelines, which only Forward+ reports) and a one-line verdict.
It also says when a run is not comparable: rows not measured at 1600x900, a `FPBENCH: WARNING` line (a hidden
window), or a row whose slow-frame detail hit the cap of 12. Both runs use the same quality presets (the street rows sweep Low,
Medium and High; the verdict is one median over all common rows), which
mean different settings per renderer (at Medium (Forward+: FSR2 at 0.77, no MSAA; Compatibility: bilinear at 1.0, MSAA 2x)),
so the verdict compares the renderer together with its render scale and antialiasing, not the renderer alone.
Exit 0 when a table was printed, 1 when a log holds no measured rows, 2 on bad usage. Offline and
read-only: it never starts the game.
"""
from __future__ import annotations

import json
import re
import statistics
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
DEVICE = re.compile(r"(Vulkan|OpenGL)[^\n]*?Using Device[^\n]*")
## Rows that are not frame-time measurements (the HUD A/B probe carries no percentiles).
NEEDED = ("p50_ms", "p99_ms", "fps")
## A median fps ratio inside this band is called a tie.
TIE = 0.05
SLOW_MS = 33.3
WANT_VIEWPORT = "1600x900"
## fp_bench.gd keeps at most this many slow-frame details per row.
MAX_HITCHES = 12
NAMES = ("forward_plus", "gl_compatibility")


def parse_log(text: str) -> dict:
    """{'rows': {label: row}, 'device': str | None, 'done': bool, 'method': str | None}."""
    text = ANSI.sub("", text)
    rows: dict = {}
    method = None
    warnings = []
    for line in text.splitlines():
        if line.startswith("FPBENCH: WARNING"):
            warnings.append(line[len("FPBENCH: "):].strip())
            continue
        if not line.startswith("FPBENCH {"):
            continue
        try:
            row = json.loads(line[len("FPBENCH "):])
        except ValueError:
            continue
        if not isinstance(row, dict) or not all(k in row for k in NEEDED) or "label" not in row:
            continue
        rows[str(row["label"])] = row
        method = method or row.get("rendering_method")
    found = DEVICE.search(text)
    return {
        "rows": rows,
        "device": found.group(0).strip() if found else None,
        "done": "FPBENCH: DONE" in text,
        "method": method,
        "warnings": warnings,
    }


def compile_hitches(row: dict):
    """Slow frames of a row that compiled pipelines; None where the engine cannot say (Compatibility)."""
    if row.get("rendering_method") == "gl_compatibility":
        return None
    hitches = row.get("hitches")
    if not isinstance(hitches, list):
        return 0
    count = 0
    for h in hitches:
        pipes = h.get("pipelines") if isinstance(h, dict) else None
        if isinstance(pipes, str):
            return None
        if isinstance(pipes, dict) and sum(int(v) for v in pipes.values()) > 0:
            count += 1
    return count


def caveats(log: dict, name: str) -> list:
    """Reasons a run's numbers need care: wrong window size, engine warnings, capped slow-frame detail."""
    out = []
    rows = log["rows"]
    odd = sorted({str(r.get("viewport")) for r in rows.values() if r.get("viewport") != WANT_VIEWPORT})
    if odd:
        out.append("%s: some rows were not measured at %s (%s); a window manager may have resized the window" % (
            name, WANT_VIEWPORT, ", ".join(odd)))
    for w in log.get("warnings", []):
        out.append("%s: %s" % (name, w))
    capped = sorted(label for label, r in rows.items() if isinstance(r.get("hitches"), list) and len(r["hitches"]) >= MAX_HITCHES)
    if capped:
        out.append("%s: slow-frame detail hit the cap of %d in %s, so the shader-compile count is a lower bound there" % (
            name, MAX_HITCHES, ", ".join(capped)))
    return out


def _num(row: dict, key: str) -> float:
    try:
        return float(row.get(key, 0.0))
    except (TypeError, ValueError):
        return 0.0


def compare(a: dict, b: dict) -> list:
    """Per-row records for the labels both logs measured, in the order of the first log."""
    out = []
    for label, ra in a["rows"].items():
        rb = b["rows"].get(label)
        if rb is None:
            continue
        fa, fb = _num(ra, "fps"), _num(rb, "fps")
        out.append({
            "label": label, "a": ra, "b": rb,
            "ratio": fa / fb if fb > 0 else 0.0,
            "p99_ratio": _num(rb, "p99_ms") / _num(ra, "p99_ms") if _num(ra, "p99_ms") > 0 else 0.0,
        })
    return out


def verdict(pairs: list, names=NAMES) -> str:
    ratios = [p["ratio"] for p in pairs if p["ratio"] > 0]
    if not ratios:
        return "VERDICT: no row was measured by both runs"
    r = statistics.median(ratios)
    rows = "%d rows" % len(ratios)
    if abs(r - 1.0) < TIE:
        return "VERDICT: Forward+ and Compatibility are within %d%% (median fps ratio %.2f over %s): keep Forward+, the full look" % (
            round(TIE * 100), r, rows)
    if r > 1.0:
        return "VERDICT: Forward+ (Vulkan) is %d%% faster than Compatibility (median fps ratio %.2f over %s): use --renderer vulkan" % (
            round((r - 1.0) * 100), r, rows)
    return "VERDICT: Compatibility (OpenGL 3) is %d%% faster than Forward+ (median fps ratio %.2f over %s) but the look differs (FSR2 against bilinear plus MSAA): use --renderer opengl3 only if Forward+ misses your frame rate" % (
        round((1.0 / r - 1.0) * 100), r, rows)


def format_table(a: dict, b: dict, names=NAMES) -> str:
    pairs = compare(a, b)
    lines = []
    for name, log in zip(names, (a, b)):
        lines.append("%-17s %s%s" % (name + ":", log["device"] or "(device line not found in the log)", "" if log["done"] else "  [run did not finish]"))
    lines.append("")
    head = "%-24s | %7s %7s %7s | %7s %7s %7s | %6s | %-11s" % ("row", "p50 ms", "p99 ms", "fps", "p50 ms", "p99 ms", "fps", "fps x", "slow >33ms")
    top = "%-24s | %-23s | %-23s | %6s | %-11s" % ("", names[0], names[1], "a / b", "a / b")
    lines += [top, head, "-" * len(head)]
    for p in pairs:
        ra, rb = p["a"], p["b"]
        slow = "%d / %d" % (int(_num(ra, "hitches_over_33ms")), int(_num(rb, "hitches_over_33ms")))
        lines.append("%-24s | %7.2f %7.2f %7.1f | %7.2f %7.2f %7.1f | %6.2f | %-11s" % (
            p["label"][:24], _num(ra, "p50_ms"), _num(ra, "p99_ms"), _num(ra, "fps"),
            _num(rb, "p50_ms"), _num(rb, "p99_ms"), _num(rb, "fps"), p["ratio"], slow))
    skipped = sorted(set(a["rows"]) ^ set(b["rows"]))
    if skipped:
        lines.append("(rows only one run measured, left out: %s)" % ", ".join(skipped))
    shader = []
    for name, side in zip(names, ("a", "b")):
        counts = [compile_hitches(p[side]) for p in pairs]
        if any(c is None for c in counts):
            shader.append("%s n/a (the engine reports no pipeline counters there)" % name)
        else:
            shader.append("%s %d" % (name, sum(counts)))
    lines.append("")
    lines.append("slow frames (>33 ms) that compiled shader pipelines: " + "; ".join(shader))
    lines.append("(each renderer at its own preset settings, e.g. Medium: Forward+ FSR2 0.77 without MSAA, Compatibility bilinear 1.0 with MSAA 2x; the street rows sweep Low, Medium and High:")
    lines.append(" the verdict compares renderer plus render scale plus antialiasing; it is a native-against-native result, not a web one)")
    notes = caveats(a, names[0]) + caveats(b, names[1])
    lines += ["CAVEAT " + n for n in notes]
    lines.append(verdict(pairs, names))
    return "\n".join(lines)


def main(argv: list) -> int:
    if len(argv) != 2 or argv[0] in ("-h", "--help"):
        sys.stderr.write((__doc__ or "").split("\n\n")[0] + "\n\nusage: bench_table.py FORWARD_PLUS.log COMPATIBILITY.log\n")
        return 2
    logs = []
    for path in argv:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                logs.append(parse_log(fh.read()))
        except OSError as err:
            sys.stderr.write("bench_table: cannot read %s: %s\n" % (path, err))
            return 2
    for path, log in zip(argv, logs):
        if not log["rows"]:
            sys.stderr.write("bench_table: no FPBENCH rows in %s (the run did not get as far as measuring)\n" % path)
            return 1
    print(format_table(logs[0], logs[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
