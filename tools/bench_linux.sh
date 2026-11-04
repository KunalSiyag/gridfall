#!/usr/bin/env bash
# GridFall renderer benchmark for your own Linux desktop: Forward+ (Vulkan) against Compatibility (OpenGL 3).
#
# usage: tools/bench_linux.sh [--out DIR] [--vsync] [--dry-run]
#        tools/bench_linux.sh --compare FORWARD_PLUS.log COMPATIBILITY.log     (no window: just the table)
# env:   GODOT (default godot)   GATE_TMP (lock and scratch dir, default /tmp/claude-1000)
#
# Opens a WINDOW (1600x900) on your display for about two minutes per renderer, twice: the same windowed
# benchmark as `tools/gate.sh render` (tools/tests/fp_bench.gd: grow a city offline, then measure the
# street on foot, the third-person camera, a sim tick and a day change), once with
# --rendering-method forward_plus and once with gl_compatibility. Then it prints one table (p50 and p99 frame
# time and fps per row, slow frames, shader-compile hitches) and a one-line verdict. Needs DISPLAY or
# WAYLAND_DISPLAY and the imported project (tools/setup.sh). Offline: no GMI key is read or sent.
# vsync is forced off so a fast GPU is not capped at your monitor's refresh (--vsync keeps it on, which
# shows the frame rate you would see, but two fast renderers then tie at the refresh rate).
# Logs and screenshots go to --out (default: a new folder under $GATE_TMP). Each run waits for the
# machine-wide heavy-run lock first, so another gate does not skew the numbers.
set -u -o pipefail

usage() {
	awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2
	exit "${1:-2}"
}

OUT=""
VSYNC=0
DRY=0
COMPARE=()
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage 0 ;;
		--out) [ $# -ge 2 ] || { echo "bench_linux: --out needs a directory" >&2; usage 2; }; OUT="$2"; shift 2 ;;
		--vsync) VSYNC=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--compare)
			[ $# -ge 3 ] || { echo "bench_linux: --compare needs two log files" >&2; usage 2; }
			COMPARE=("$2" "$3"); shift 3 ;;
		*) echo "bench_linux: unknown argument '$1'" >&2; usage 2 ;;
	esac
done

cd "$(dirname "$0")/.." || exit 2
TABLE=(python3 -I tools/bench_table.py)

if [ "${#COMPARE[@]}" -eq 2 ]; then
	exec "${TABLE[@]}" "${COMPARE[0]}" "${COMPARE[1]}"
fi

if [ "$DRY" -eq 0 ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	echo "bench_linux: no DISPLAY or WAYLAND_DISPLAY: this benchmark opens a real window and cannot run headless." >&2
	echo "bench_linux: run it from a terminal on your desktop session (or use --compare on two saved logs)." >&2
	exit 2
fi

GODOT="${GODOT:-godot}"
GATE_TMP="${GATE_TMP:-/tmp/claude-1000}"
if [ "$DRY" -eq 0 ]; then
	command -v "$GODOT" >/dev/null 2>&1 || { echo "bench_linux: Godot binary '$GODOT' not found (set GODOT=/path/to/godot)" >&2; exit 2; }
	command -v python3 >/dev/null 2>&1 || { echo "bench_linux: python3 not found" >&2; exit 2; }
fi
mkdir -p "$GATE_TMP"
[ -n "$OUT" ] || OUT="$GATE_TMP/gf-bench-linux-$(date -u +%Y%m%dT%H%M%SZ)"
LOCK="$GATE_TMP/gf-heavy.lock"

ARGS_COMMON=(--path . --resolution 1600x900 --audio-driver Dummy)
[ "$VSYNC" -eq 0 ] && ARGS_COMMON+=(--disable-vsync)

run_one() {
	local method="$1" log="$OUT/fp_bench_$1.log" xdg="FRESH_TMPDIR"
	[ "$DRY" -eq 1 ] || xdg="$(mktemp -d "$GATE_TMP/gf-xdg.XXXXXX")"
	local cmd=(env -u GMI_API_KEY -u GRIDFALL_RECORD -u GRIDFALL_VIEW -u GRIDFALL_SPEED -u GRIDFALL_HOUR -u GRIDFALL_RESIDENTS
		"XDG_DATA_HOME=$xdg" GRIDFALL_OFFLINE=1 "FPBENCH_DIR=$OUT/shots_$method"
		timeout -s SEGV -k 30 400 "$GODOT" "${ARGS_COMMON[@]}" --rendering-method "$method" -s tools/tests/fp_bench.gd)
	if [ "$DRY" -eq 1 ]; then
		printf '%q ' "${cmd[@]}"; echo
		return 0
	fi
	mkdir -p "$OUT/shots_$method"
	echo "bench_linux: $method: a 1600x900 window opens now (about two minutes) ..." >&2
	if command -v flock >/dev/null 2>&1; then
		flock -w 3600 "$LOCK" "${cmd[@]}" > "$log" 2>&1
	else
		"${cmd[@]}" > "$log" 2>&1
	fi
	local rc=$?
	rm -rf "$xdg"
	if ! grep -q '^FPBENCH: DONE' "$log"; then
		echo "bench_linux: $method did not finish (exit $rc); last lines of $log:" >&2
		tail -n 8 "$log" >&2
		return 1
	fi
	return 0
}

echo "bench_linux: this opens a window on your display, twice (forward_plus, then gl_compatibility); logs in $OUT" >&2
fail=0
run_one forward_plus || fail=1
run_one gl_compatibility || fail=1
if [ "$DRY" -eq 1 ]; then
	exit 0
fi
if [ "$fail" -ne 0 ] && { [ ! -s "$OUT/fp_bench_forward_plus.log" ] || [ ! -s "$OUT/fp_bench_gl_compatibility.log" ]; }; then
	exit 1
fi
"${TABLE[@]}" "$OUT/fp_bench_forward_plus.log" "$OUT/fp_bench_gl_compatibility.log"
rc=$?
echo "logs: $OUT" >&2
[ "$fail" -eq 0 ] && exit "$rc"
exit 1
