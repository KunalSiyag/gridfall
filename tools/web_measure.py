#!/usr/bin/env python3
"""Measure a live (or local) GridFall web deployment: per-file encoding and first-load bytes.

Reusable after every deploy: it asks the origin what it actually serves, then boots the game in a
headless Chromium and reports the bytes that crossed the wire and how long the first frame took.

usage:
  tools/web_measure.py https://<host>/                 # headers + browser first load
  tools/web_measure.py https://<host>/ --headers-only  # curl-level check, no browser
  tools/web_measure.py http://127.0.0.1:8080/ --browser-timeout 900
  tools/web_measure.py --budget [--hz 60 --hz 120]     # the droid's budget table in busy ms plus display Hz
  tools/web_measure.py --lanes                         # its day-10 lanes against each display's vsync steps
  tools/web_measure.py --probe-report <outdir>/result.json [--hz 60]   # a web_fps_probe.js run the same way

needs: python3 (stdlib only), and for the browser half the same setup as deploy/web/smoke.js
(Chrome plus a resolvable playwright-core; set NODE_PATH if it lives outside the repo).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ASSET_RE = re.compile(r'"(?:executable|serviceWorker)":"([^"]+)"|"fileSizes":\{([^}]*)\}')


def fetch(url: str, headers: dict) -> tuple:
    request = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=120) as response:
        body = response.read()
        return response.status, dict(response.headers), body


def head(url: str, encoding: str) -> dict:
    status, headers, body = fetch(url, {"Accept-Encoding": encoding, "Range": "bytes=0-0"})
    # HTTP field names are case-insensitive; converting HTTPMessage to dict loses that lookup.
    headers = {name.lower(): value for name, value in headers.items()}
    return {
        "status": status,
        "encoding": headers.get("content-encoding", "identity"),
        "cache": headers.get("cache-control", ""),
        "coop": headers.get("cross-origin-opener-policy", ""),
        "coep": headers.get("cross-origin-embedder-policy", ""),
        "type": headers.get("content-type", ""),
        "content_range": headers.get("content-range", ""),
        "probe_bytes": len(body),
    }


def asset_paths(html: str) -> list[str]:
    """The asset URLs a loader page names: srcs, hrefs and the fileSizes keys.

    The executable value is a basename (the engine appends `.pck`/`.wasm`), so it is not a URL;
    the fileSizes keys are.
    """
    found = list(re.findall(r'(?:src|href)="([^"]+)"', html))
    found += re.findall(r'"([^"]*\.(?:pck|wasm|js|json|html|png))":\d+', html)
    out = [""]
    for path in found:
        if path.startswith(("http:", "https:", "data:", "#")):
            continue
        cleaned = path.lstrip("/")
        if cleaned not in out:
            out.append(cleaned)
    return out


def targets(base: str) -> list[str]:
    """The loader page plus every asset the page itself names."""
    status, headers, body = fetch(base, {})
    return asset_paths(body.decode("utf-8", "replace"))


def header_report(base: str) -> list:
    rows = []
    for path in targets(base):
        url = base.rstrip("/") + "/" + path
        for encoding in ("br", "gzip", "identity"):
            try:
                info = head(url, encoding)
            except Exception as error:  # noqa: BLE001 - a probe failure is a finding, not a crash
                rows.append({"path": path or "/", "accept": encoding, "error": str(error)[:120]})
                continue
            rows.append({"path": path or "/", "accept": encoding, **info})
    return rows


def browser_load(base: str, timeout_ms: int, node_path: str) -> dict:
    """Boot the page in headless Chromium and report wire bytes plus time to the first frame."""
    script = Path(tempfile.mkdtemp(prefix="gf-measure-")) / "load.js"
    script.write_text(MEASURE_JS)
    env = dict(os.environ)
    if node_path:
        env["NODE_PATH"] = node_path
    env["GF_MEASURE_URL"] = base
    env["GF_MEASURE_TIMEOUT"] = str(timeout_ms)
    result = subprocess.run(
        ["node", str(script)], env=env, capture_output=True, text=True, timeout=timeout_ms / 1000 + 120,
    )
    if result.returncode != 0:
        return {"error": (result.stderr or result.stdout).strip()[-400:]}
    for line in reversed(result.stdout.splitlines()):
        if line.startswith("GF_MEASURE "):
            return json.loads(line[len("GF_MEASURE "):])
    return {"error": "no measurement line", "stdout": result.stdout[-400:]}


MEASURE_JS = r"""
const { chromium } = require("playwright-core");
const URL_ = process.env.GF_MEASURE_URL;
const TIMEOUT = Number(process.env.GF_MEASURE_TIMEOUT || 600000);
const CHROME = process.env.GF_MEASURE_CHROME || "/usr/bin/google-chrome";

(async () => {
	const browser = await chromium.launch({
		executablePath: CHROME, headless: true,
		args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader",
			"--disable-dev-shm-usage", "--no-sandbox"],
	});
	const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
	const files = [];
	let bytes = 0;
	page.on("response", async (r) => {
		const h = r.headers();
		try {
			const s = await r.request().sizes();
			bytes += s.responseBodySize + s.responseHeadersSize;
			files.push({ url: r.url().replace(URL_.replace(/\/$/, ""), ""), status: r.status(),
				encoding: h["content-encoding"] || "identity", wire: s.responseBodySize });
		} catch (e) {}
	});
	const t0 = Date.now();
	await page.goto(URL_, { waitUntil: "domcontentloaded", timeout: 60000 });
	let firstFrameMs = null;
	const deadline = Date.now() + TIMEOUT;
	while (Date.now() < deadline) {
		const drawn = await page.evaluate(() => {
			const c = document.querySelector("canvas");
			if (!c) return false;
			try {
				const gl = c.getContext("webgl2") || c.getContext("webgl");
				if (!gl) return false;
				// The engine clears to the page background until it renders; sample a few pixels.
				const px = new Uint8Array(4 * 16);
				gl.readPixels(0, 0, 4, 4, gl.RGBA, gl.UNSIGNED_BYTE, px);
				return px.some((v, i) => i % 4 !== 3 && v > 8);
			} catch (e) { return false; }
		}).catch(() => false);
		if (drawn) { firstFrameMs = Date.now() - t0; break; }
		await new Promise((r) => setTimeout(r, 500));
	}
	const coi = await page.evaluate(() => crossOriginIsolated).catch(() => null);
	const byEncoding = {};
	for (const f of files) byEncoding[f.encoding] = (byEncoding[f.encoding] || 0) + f.wire;
	const big = files.filter((f) => f.wire > 100000).sort((a, b) => b.wire - a.wire);
	console.log("GF_MEASURE " + JSON.stringify({
		first_frame_ms: firstFrameMs, wire_bytes: bytes, cross_origin_isolated: coi,
		by_encoding: byEncoding, big_files: big, files: files.length,
	}));
	await browser.close();
})().catch((e) => { console.error("GF_MEASURE ERROR", e); process.exit(2); });
"""


# --- frame budget in busy ms and display Hz --------------------------------------------------------
#
# On a vsync-locked display the interval between frames is a whole number of refresh periods, so a
# CPU saving changes nothing a player sees until the frame's busy time crosses a vsync boundary
# (34 ms busy shows 20 fps on 60 Hz, 31 ms shows 30). "Busy" is what the slowest stage of the frame
# (the main thread, or the GPU process behind it) needed; the interval is that rounded up to the
# next vsync. n vsyncs therefore bound busy to ((n - 1) periods, n periods]. A value that is not a
# whole number of periods (a mean, a median of mixed frames, a different clock) is only bounded by
# (interval - period, interval].

# The display of the droid's rAF measurements: its live p50/p95 values are exact multiples of 6.944 ms.
DROID_HZ = 144.0
# How far from a whole number of vsyncs an interval may be and still count as vsync-locked.
LOCK_TOLERANCE = 0.15
# (row, interval ms, where it stands) from docs/round4/web-perf-budget.md in the factory space.
# The live rows ("Live post-deploy numbers", 2026-10-28, shipped threaded build) and the bench rows
# (day-10 city, "Day-10 street attribution v4" and "Absolute re-measure", 2026-10-30, Godot frame
# deltas) are percentiles. The last six are the doc's "Shipped build frame budget" table (the
# round's earliest, no-threads build, 20 s rAF windows, display rate not stated); they are not whole
# vsyncs, so they only bound busy. A mean of frames that alternate between two vsync counts is
# never a locked value.
BUDGET_ROWS = [
    ("day-1 street, p50", 13.9, "live 58.3 fps"),
    ("day-10 street, p50", 41.7, "live 23.4 fps"),
    ("day-10 street, p95", 62.5, "live, same window"),
    ("day-10 street_tick, p50", 56.2, "bench 17.5 fps (v4)"),
    ("day-10 street_day_end, p50", 61.0, "bench 15.5 fps"),
    ("quiet street, p50", 24.7, "early table, avg 26.0"),
    ("quiet street, p90", 32.7, "early table"),
    ("orbit, p50", 22.9, "early table, avg 26.2"),
    ("orbit, p90", 37.7, "early table"),
    ("busier street, p50", 43.0, "early table, avg 61.6"),
    ("busier street, p90", 101.0, "early table"),
]
DEFAULT_TARGETS = (60.0, 120.0)
# The day-10 street_tick frame split by lane: the doc's "Day-10 street attribution v4" table (garage,
# 2026-10-30, quiet box, frame avg 57.1 ms, p50 56.2). The lanes are node timers, so they are busy time;
# the floor is the doc's residual against the frame interval, so it also holds the vsync slack of the
# 144 Hz display it was measured on. The in-flight CPU lanes are the doc's "next lane 2": traffic 3.5 +
# Weather 1.5 + animals 1.6 = 6.6 ms, "realistic ~3 ms".
LANE_FRAME_MS = 57.1
LANES = [
    ("render CPU", 13.0),
    ("traffic_feature", 3.5),
    ("sim slice + CitySim wrapper", 3.8),
    ("animals_feature", 1.6),
    ("Weather", 1.5),
    ("audio_feature", 1.2),
    ("CityView", 1.1),
    ("physics frames", 0.0),
    ("everything else", 1.5),
    ("engine/browser floor (residual)", 30.0),
]
IN_FLIGHT_LANES = ("traffic_feature", "animals_feature", "Weather")
LANE_TARGETS = (60.0, 120.0, 144.0)


def vsync_ms(hz: float) -> float:
    return 1000.0 / hz


def whole_vsyncs(interval_ms: float, hz: float) -> int | None:
    """The number of refresh periods interval_ms is, when it is a whole number of them, else None."""
    n = interval_ms / vsync_ms(hz)
    return round(n) if round(n) >= 1 and abs(n - round(n)) <= LOCK_TOLERANCE else None


def busy_bounds(interval_ms: float, hz: float) -> tuple[float, float]:
    """(low, high]: the busy time an interval measured on a display at hz implies."""
    period = vsync_ms(hz)
    n = whole_vsyncs(interval_ms, hz)
    if n is not None:
        return (n - 1) * period, n * period
    return max(0.0, interval_ms - period), interval_ms


def snap_interval(busy_ms: float, hz: float) -> float:
    """The interval a display at hz shows for a frame that needs busy_ms: the next vsync boundary."""
    period = vsync_ms(hz)
    return max(1, math.ceil(busy_ms / period - 1e-9)) * period


def cut_to_step(busy_ms: float, hz: float) -> float:
    """Milliseconds to take off busy_ms to show one vsync less (0 within the first refresh period)."""
    period = vsync_ms(hz)
    vsyncs = max(1, math.ceil(busy_ms / period - 1e-9))
    return 0.0 if vsyncs <= 1 else busy_ms - (vsyncs - 1) * period


def step_segments(low: float, high: float, hz: float) -> list[tuple[int, float, float]]:
    """The pieces of the busy range (low, high] by how many refresh periods each shows on a display
    at hz: [(vsyncs, busy from, busy to)]. One piece unless the range straddles a vsync boundary."""
    period = vsync_ms(hz)
    first = math.floor(low / period + 1e-9) + 1
    last = max(first, math.ceil(high / period - 1e-9))
    return [(k, max(low, (k - 1) * period), min(high, k * period)) for k in range(first, last + 1)]


def merge_ranges(ranges: list[list[float]]) -> list[list[float]]:
    """Sorted, with overlapping or touching [low, high] ranges joined."""
    out: list[list[float]] = []
    for lo, hi in sorted(ranges):
        if out and lo <= out[-1][1] + 1e-9:
            out[-1][1] = max(out[-1][1], hi)
        else:
            out.append([lo, hi])
    return out


def restate_row(name: str, interval_ms: float, source_hz: float, target_hz: float) -> dict:
    """One measured interval as busy ms, and what a display at target_hz would show for it."""
    low, high = busy_bounds(interval_ms, source_hz)
    period = vsync_ms(target_hz)
    segments = step_segments(low, high, target_hz)
    shown = [k * period for k, _, _ in segments]
    # The cut that drops a piece one vsync is how far its busy time sits above the previous
    # boundary: anywhere in (0, period] across a whole piece, and 0 on the first vsync.
    cuts = merge_ranges([
        [0.0, 0.0] if k == 1 else [b_lo - (k - 1) * period, b_hi - (k - 1) * period]
        for k, b_lo, b_hi in segments
    ])
    return {
        "name": name,
        "interval_ms": interval_ms,
        "source_hz": source_hz,
        "vsyncs": round(interval_ms / vsync_ms(source_hz), 2),
        "locked": whole_vsyncs(interval_ms, source_hz) is not None,
        "busy_ms": [round(low, 1), round(high, 1)],
        "target_hz": target_hz,
        "target_interval_ms": [round(v, 1) for v in shown],
        "target_fps": [round(1000.0 / v, 1) for v in reversed(shown)],
        "cut_ms": [[round(lo, 1), round(hi, 1)] for lo, hi in cuts],
    }


def budget_table(targets: tuple = DEFAULT_TARGETS, source_hz: float = DROID_HZ) -> list[dict]:
    """The droid's budget rows restated for each target display rate."""
    return [
        dict(restate_row(name, interval, source_hz, hz), where=where)
        for name, interval, where in BUDGET_ROWS
        for hz in targets
    ]


def shown_fps(low: float, high: float, hz: float) -> list[float]:
    """The frame rate(s) a display at hz shows for a frame whose busy time lies in (low, high]: one
    value, or several (ascending) when the range straddles a vsync boundary."""
    period = vsync_ms(hz)
    return sorted(round(1000.0 / (k * period), 1) for k, _, _ in step_segments(low, high, hz))


def lane_table(targets: tuple = LANE_TARGETS, frame_ms: float = LANE_FRAME_MS,
               source_hz: float = DROID_HZ) -> list[dict]:
    """The v4 lanes against the vsync steps: for each lane (and for the in-flight lanes together) the
    frame rate each display would show if it cost nothing. The frame's busy time is only known within
    one period of the display it was measured on (busy_bounds), so a lane that may or may not cross a
    vsync boundary shows both rates."""
    low, high = busy_bounds(frame_ms, source_hz)
    in_flight = round(sum(ms for name, ms in LANES if name in IN_FLIGHT_LANES), 1)
    # (row, ms the row costs, ms taken off the frame): the first row is the frame itself, nothing removed.
    entries = [("frame as measured", frame_ms, 0.0), *((name, ms, ms) for name, ms in LANES),
               ("in-flight lanes: " + " + ".join(IN_FLIGHT_LANES), in_flight, in_flight)]
    rows = []
    for name, ms, removed in entries:
        lo, hi = max(0.0, low - removed), max(0.0, high - removed)
        rows.append({
            "lane": name,
            "ms": ms,
            "share_pct": round(100.0 * ms / frame_ms, 1),
            "busy_ms": [round(lo, 1), round(hi, 1)],
            "fps": {f"{hz:g}": shown_fps(lo, hi, hz) for hz in targets},
        })
    return rows


# The result.json layout tools/web_fps_probe.js writes (its RESULT_SCHEMA).
PROBE_SCHEMA = 1


def probe_source_hz(result: dict, override: float | None = None) -> tuple[float, str]:
    """(rate, how): the display rate a probe result's intervals were measured at, and where that came
    from: the --source-hz given, the probe's own measurement, or the droid's display as a last resort."""
    if override:
        return float(override), "--source-hz"
    shown = (result.get("env") or {}).get("display_hz") or {}
    for key in ("nominal", "hz"):
        if shown.get(key):
            return float(shown[key]), f"measured by the probe ({key})"
    return DROID_HZ, f"ASSUMED, the result has no display_hz: the droid's {DROID_HZ:g} Hz"


def probe_notes(result: dict, source_hz: float | None = None) -> list[str]:
    """What a reader of probe_rows() must know about the result: the display rate assumed, a software
    renderer's milliseconds, an unknown layout."""
    notes = []
    rate, how = probe_source_hz(result, source_hz)
    notes.append(f"display rate of the measured intervals: {rate:g} Hz ({how})")
    if result.get("hardware") is False:
        notes.append(
            f"software renderer ({result.get('renderer') or 'unknown'}): the milliseconds are a software "
            "rasterizer's and do not transfer to a real GPU; read the vsync arithmetic as structure, not as a budget"
        )
    schema = result.get("schema")
    if schema is None:
        notes.append("the result has no schema field: written by a probe older than schema 1, keys may differ")
    elif schema != PROBE_SCHEMA:
        notes.append(f"the result has schema {schema}, this reader knows {PROBE_SCHEMA}: keys may have moved")
    return notes


def probe_rows(result: dict, targets: tuple = DEFAULT_TARGETS, source_hz: float | None = None) -> list[dict]:
    """The rows of a web_fps_probe.js result.json, restated: p50 and p95 as intervals at the
    display rate the probe measured (source_hz overrides it), plus the measured main-thread busy
    time shown at each target."""
    source, how = probe_source_hz(result, source_hz)
    where = f"probe {source:g} Hz" + (" ASSUMED" if how.startswith("ASSUMED") else "")
    out = []
    for label in ("street", "walk", "sky", "orbit"):
        row = result.get(label)
        if not row:
            continue
        for hz in targets:
            for key in ("p50_ms", "p95_ms"):
                if row.get(key):
                    out.append(dict(restate_row(f"{label} {key[:3]}", float(row[key]), source, hz), where=where))
            busy = (row.get("busy_ms") or {}).get("p50")
            if busy:
                interval = snap_interval(float(busy), hz)
                out.append({
                    "name": f"{label} measured busy p50", "interval_ms": None, "source_hz": source, "vsyncs": None,
                    "locked": None, "busy_ms": [float(busy), float(busy)], "target_hz": hz,
                    "target_interval_ms": [round(interval, 1)], "target_fps": [round(1000.0 / interval, 1)],
                    "cut_ms": [[round(cut_to_step(float(busy), hz), 1)] * 2], "where": "rAF callback time",
                })
    return out


def _span(values: list, unit: str = "") -> str:
    return f"{values[0]:g}{unit}" if len(values) == 1 or values[0] == values[-1] else f"{values[0]:g}-{values[-1]:g}{unit}"


def _ranges(ranges: list, unit: str = "") -> str:
    """[[lo, hi], ...] as "lo-hi | lo-hi", a range of one value as that value."""
    return " | ".join(_span(r) for r in ranges) + unit


def format_table(rows: list[dict]) -> str:
    """Rows from budget_table() or probe_rows() as a text table."""
    head = (f"{'row':<30} {'measured':>10} {'vsyncs':>7} {'busy ms':>11} | {'display':>7} {'shows ms':>10} "
            f"{'fps':>9} {'cut for a step':>22}  where")
    lines = [head, "-" * len(head)]
    for r in rows:
        measured = "-" if r["interval_ms"] is None else f"{r['interval_ms']:g}"
        vsyncs = "-" if r["vsyncs"] is None else f"{r['vsyncs']:g}" + ("" if r["locked"] else "?")
        lines.append(
            f"{r['name']:<30} {measured:>10} {vsyncs:>7} {_span(r['busy_ms']):>11} | {r['target_hz']:>5g}Hz "
            f"{_span(r['target_interval_ms']):>10} {_span(r['target_fps']):>9} {_ranges(r['cut_ms'], ' ms'):>22}"
            f"  {r.get('where', '')}"
        )
    lines.append("busy = what the slowest stage of the frame needed; '?' = not a whole number of vsyncs "
                 "(a mean or a different clock), so busy is only bounded by the interval.")
    lines.append("cut for a step = the milliseconds to take off busy to show one vsync less on that display "
                 "(a range, as busy is only known within one period; 0 ms = already on the first vsync).")
    return "\n".join(lines)


def format_lanes(rows: list[dict], targets: tuple = LANE_TARGETS) -> str:
    """Rows from lane_table() as a text table."""
    head = f"{'lane (street_tick, day 10)':<62} {'ms':>5} {'share':>6} {'busy if free':>13} | " + " ".join(
        f"{hz:>5g}Hz" for hz in targets)
    lines = [head, "-" * len(head)]
    for r in rows:
        shown = " ".join(f"{_span(r['fps'][f'{hz:g}']):>7}" for hz in targets)
        lines.append(f"{r['lane']:<62} {r['ms']:>5g} {r['share_pct']:>5g}% {_span(r['busy_ms']):>13} | {shown}")
    lines.append("fps = what a display at that rate shows if the lane cost nothing; a range = the lane may or may "
                 "not cross a vsync boundary (busy is only known within one period of the display it was measured on).")
    lines.append("A percentile or one busy time steps in these units; a mean over frames spread across several "
                 "vsyncs does not, so the same saving moves average fps smoothly and by less.")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?")
    parser.add_argument("--headers-only", action="store_true")
    parser.add_argument("--browser-timeout", type=int, default=600000)
    parser.add_argument("--node-path", default=os.environ.get("NODE_PATH", ""))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--budget", action="store_true", help="restate the droid's budget rows in busy ms")
    parser.add_argument("--lanes", action="store_true", help="the day-10 frame's lanes against the vsync steps")
    parser.add_argument("--probe-report", metavar="RESULT_JSON", help="restate a web_fps_probe.js result")
    parser.add_argument("--hz", type=float, action="append",
                        help="display rate(s) to show (default 60 and 120; 60, 120 and 144 for --lanes)")
    parser.add_argument("--source-hz", type=float, default=None,
                        help="display rate the measured rows were taken at (default: the droid's 144 Hz for "
                             "--budget and --lanes, the result's own display_hz for --probe-report)")
    args = parser.parse_args(argv)
    targets = tuple(args.hz) if args.hz else DEFAULT_TARGETS
    if args.lanes:
        lane_targets = tuple(args.hz) if args.hz else LANE_TARGETS
        rows = lane_table(lane_targets, source_hz=args.source_hz or DROID_HZ)
        print(json.dumps(rows) if args.json else format_lanes(rows, lane_targets))
        return
    if args.budget or args.probe_report:
        if args.budget:
            rows = budget_table(targets, args.source_hz or DROID_HZ)
        else:
            result = json.loads(Path(args.probe_report).read_text(encoding="utf-8"))
            rows = probe_rows(result, targets, args.source_hz)
            # Notes beside the table, or on stderr so a --json reader still gets only the rows.
            notes = "\n".join("NOTE: " + n for n in probe_notes(result, args.source_hz))
            print(notes, file=sys.stderr if args.json else sys.stdout)
        print(json.dumps(rows) if args.json else format_table(rows))
        return
    if not args.url:
        parser.error("url is required unless --budget, --lanes or --probe-report is given")
    base = args.url.rstrip("/") + "/"
    rows = header_report(base)
    print("== per-file encoding (probe: 1 byte via Range) ==")
    for row in rows:
        if "error" in row:
            print(f"  {row['path']:<44} {row['accept']:<9} ERROR {row['error']}")
            continue
        print(f"  {row['path']:<44} {row['accept']:<9} {row['status']} enc={row['encoding']:<8} "
              f"cache={row['cache']:<38} coop={row['coop'] or '-'} coep={row['coep'] or '-'}")
    result = {"headers": rows}
    if not args.headers_only:
        print("== browser first load ==")
        result["browser"] = browser_load(base, args.browser_timeout, args.node_path)
        print(json.dumps(result["browser"], indent=2)[:2000])
    if args.json:
        print("GF_MEASURE_JSON " + json.dumps(result))
    if any("error" in row for row in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()
