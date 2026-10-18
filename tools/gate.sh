#!/usr/bin/env bash
# GridFall gate (docs/fp/S0-foundation.md §18).
#
# usage: tools/gate.sh quick|full|render [--only <step-substring>] [--keep]
# env:   GODOT (default: godot)   GATE_LOG_DIR (default: /tmp/claude-1000/gf-gate-<branch>-<UTC ts>)
#        DISPLAY (render only; default :1)
#
# quick:  parse_all, the five legacy unit tests, every tools/tests/fp_*_test.gd
# full:   quick + orbit smoke + FP smoke (headless, heavy)
# render: FP photo tour + fp_bench (windowed, heavy); perf numbers are report-only
#
# Every Godot run gets a fresh XDG_DATA_HOME (the smokes save games), GRIDFALL_OFFLINE=1, no GMI
# key and a timeout. Heavy runs hold the machine-wide lock /tmp/claude-1000/gf-heavy.lock.
set -u -o pipefail

usage() {
	sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

MODE="${1:-}"
case "$MODE" in
	quick|full|render) shift ;;
	*) usage ;;
esac
ONLY=""
KEEP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--only) [ $# -ge 2 ] || usage; ONLY="$2"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		*) usage ;;
	esac
done

cd "$(dirname "$0")/.." || exit 2
GODOT="${GODOT:-godot}"
LOCK=/tmp/claude-1000/gf-heavy.lock
mkdir -p /tmp/claude-1000
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || echo nobranch)"
GATE_LOG_DIR="${GATE_LOG_DIR:-/tmp/claude-1000/gf-gate-${BRANCH}-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$GATE_LOG_DIR"
XDG_DIRS=()
cleanup() {
	if [ "$KEEP" -eq 0 ]; then
		for d in "${XDG_DIRS[@]+"${XDG_DIRS[@]}"}"; do rm -rf "$d"; done
	fi
}
trap cleanup EXIT

NAMES=()
RESULTS=()
SECS=()
LOGS=()
FAILED=0

# run_step <name> <token> <timeout> <heavy:0|1> -- <env...> -- <godot args...>
run_step() {
	local name="$1" token="$2" tmo="$3" heavy="$4"
	shift 4
	[ "${1:-}" = "--" ] && shift
	local envs=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
	[ "${1:-}" = "--" ] && shift
	if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then
		return 0
	fi
	local log="$GATE_LOG_DIR/$name.log"
	local xdg
	xdg="$(mktemp -d /tmp/claude-1000/gf-xdg.XXXXXX)"
	XDG_DIRS+=("$xdg")
	local cmd=(env -u GMI_API_KEY -u GRIDFALL_RECORD -u GRIDFALL_VIEW -u GRIDFALL_SPEED -u GRIDFALL_HOUR -u GRIDFALL_RESIDENTS
		"XDG_DATA_HOME=$xdg" GRIDFALL_OFFLINE=1 "${envs[@]+"${envs[@]}"}" timeout "$tmo" "$GODOT" "$@")
	if [ "$heavy" = "1" ]; then
		cmd=(flock -w 3600 "$LOCK" "${cmd[@]}")
	fi
	printf '%-28s ...\r' "$name" >&2
	local t0 rc
	t0=$(date +%s)
	"${cmd[@]}" >"$log" 2>&1
	rc=$?
	local secs=$(( $(date +%s) - t0 ))
	local res
	if [ "$rc" -eq 124 ]; then
		res="TIMEOUT"
	elif grep -qE 'SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|No loader found' "$log"; then
		res="FAIL(script-error)"
	elif ! grep -qF -- "$token" "$log"; then
		res="FAIL(no-token)"
	elif [ "$rc" -ne 0 ]; then
		res="FAIL(exit=$rc)"
	else
		res="PASS"
	fi
	NAMES+=("$name"); RESULTS+=("$res"); SECS+=("$secs"); LOGS+=("$log")
	[ "$res" = "PASS" ] || FAILED=$((FAILED + 1))
	printf '%-28s %s (%ss)\n' "$name" "$res" "$secs" >&2
	return 0
}

# Overrides a recorded result (used when a step's own checks go beyond its token).
set_last_result() {
	local n=$(( ${#RESULTS[@]} - 1 ))
	[ "$n" -ge 0 ] || return 0
	if [ "${RESULTS[$n]}" = "PASS" ] && [ "$1" != "PASS" ]; then FAILED=$((FAILED + 1)); fi
	RESULTS[$n]="$1"
}

# Import pre-flight (D-S0-22): a cold or stale .godot cache, newer assets or .import files, or newer
# scripts (new class_name entries live in .godot/global_script_class_cache.cfg) trigger an import.
STAMP=.godot/gate_import.stamp
needs_import() {
	[ -d .godot/imported ] || return 0
	[ -n "$(ls -A .godot/imported 2>/dev/null)" ] || return 0
	[ -f .godot/global_script_class_cache.cfg ] || return 0
	[ -f "$STAMP" ] || return 0
	[ -n "$(find . -path ./.godot -prune -o -name '*.import' -newer "$STAMP" -print -quit)" ] && return 0
	[ -n "$(find . -path ./.godot -prune -o \( -name '*.gd' -o -name 'project.godot' \) -newer "$STAMP" -print -quit)" ] && return 0
	local d
	for d in models textures env sounds assets; do
		[ -d "$d" ] || continue
		[ -n "$(find "$d" -type f ! -name '*.import' -newer "$STAMP" -print -quit)" ] && return 0
	done
	return 1
}
if needs_import; then
	echo "gate: importing (cold or stale .godot cache)..." >&2
	only_saved="$ONLY"
	ONLY=""
	# The import prints no token; an empty token matches any output, so exit code and loader errors decide.
	run_step import "" 900 1 -- -- --headless --path . --import
	ONLY="$only_saved"
	if [ "${RESULTS[$(( ${#RESULTS[@]} - 1 ))]}" = "PASS" ]; then
		touch "$STAMP"
	fi
fi

if [ "$MODE" = "quick" ] || [ "$MODE" = "full" ]; then
	run_step parse_all "PARSE_ALL: PASS" 180 0 -- -- --headless --path . -s tools/tests/parse_all.gd
	for t in sim_test buildings_test residents_test expansion_test construction_test; do
		tok="$(echo "$t" | tr '[:lower:]' '[:upper:]'): PASS"
		run_step "$t" "$tok" 300 0 -- -- --headless --path . -s "tools/tests/$t.gd"
	done
	for f in $(ls tools/tests/fp_*_test.gd 2>/dev/null | sort); do
		t="$(basename "$f" .gd)"
		tok="$(echo "$t" | tr '[:lower:]' '[:upper:]'): PASS"
		run_step "$t" "$tok" 300 0 -- -- --headless --path . -s "$f"
	done
fi

if [ "$MODE" = "full" ]; then
	run_step orbit_smoke "GRIDFALL_SMOKE: PASS" 400 1 -- GRIDFALL_SMOKE_TEST=1 -- --headless --path .
	run_step fp_smoke "FP_SMOKE: PASS" 400 1 -- GRIDFALL_FP_SMOKE=1 -- --headless --path .
fi

PHOTO_DIR="$GATE_LOG_DIR/photos"
BENCH_DIR="$GATE_LOG_DIR/bench"
if [ "$MODE" = "render" ]; then
	DISP="${DISPLAY:-:1}"
	before=${#RESULTS[@]}
	run_step fp_photo "FP_PHOTO: DONE" 400 1 -- "DISPLAY=$DISP" "GRIDFALL_FP_PHOTO_DIR=$PHOTO_DIR" GRIDFALL_PHOTO_DAYS=6 -- --path . --resolution 1600x900 --audio-driver Dummy
	if [ ${#RESULTS[@]} -gt "$before" ] && [ "${RESULTS[$before]}" = "PASS" ]; then
		missing=0
		for s in street intersection downtown park residential river dusk night; do
			for v in "$s.png" "${s}_hud.png"; do
				[ -s "$PHOTO_DIR/$v" ] || { missing=$((missing + 1)); echo "gate: missing photo $v" >&2; }
			done
		done
		[ "$missing" -eq 0 ] || set_last_result "FAIL(photos)"
		# D11 targets 1600x900; a window manager may open the window smaller than --resolution.
		if [ "$missing" -eq 0 ] && ! grep -qE '^FP_PHOTO: DONE .* size=1600x900' "$GATE_LOG_DIR/fp_photo.log"; then
			echo "gate: photos were not taken at 1600x900: $(grep -E '^FP_PHOTO: DONE' "$GATE_LOG_DIR/fp_photo.log")" >&2
			set_last_result "FAIL(size)"
		fi
	fi
	before=${#RESULTS[@]}
	run_step fp_bench "FPBENCH: DONE" 400 1 -- "DISPLAY=$DISP" "FPBENCH_DIR=$BENCH_DIR" -- --path . --resolution 1600x900 --audio-driver Dummy -s tools/tests/fp_bench.gd
	if [ ${#RESULTS[@]} -gt "$before" ] && [ "${RESULTS[$before]}" = "PASS" ]; then
		rows=$(grep -cE '^FPBENCH \{' "$GATE_LOG_DIR/fp_bench.log")
		good=$(grep -cE '^FPBENCH \{.*"viewport":"1600x900"' "$GATE_LOG_DIR/fp_bench.log")
		if [ "$rows" -eq 0 ] || [ "$rows" -ne "$good" ]; then
			echo "gate: fp_bench measured $good of $rows rows at 1600x900" >&2
			set_last_result "FAIL(size)"
		fi
	fi
fi

echo
printf '%-28s | %-20s | %5s | %s\n' STEP RESULT SECS LOG
printf '%s\n' "-----------------------------+----------------------+-------+------------------------------"
for i in "${!NAMES[@]}"; do
	printf '%-28s | %-20s | %5s | %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${SECS[$i]}" "${LOGS[$i]}"
done
if [ "$MODE" = "render" ]; then
	if [ -f "$GATE_LOG_DIR/fp_bench.log" ]; then
		echo
		echo "FPBENCH (report-only)"
		grep -E '^FPBENCH \{' "$GATE_LOG_DIR/fp_bench.log" | sed 's/^FPBENCH //' | python3 -I -c '
import json, sys
print("%-20s %7s %8s %8s %8s %7s %8s %10s" % ("label", "fps", "avg", "p99", "max", "draws", "vram_mb", "viewport"))
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    print("%-20s %7s %8s %8s %8s %7s %8s %10s" % (r.get("label"), r.get("fps"), r.get("avg_ms"), r.get("p99_ms"), r.get("max_ms"), int(r.get("draws", 0)), r.get("vram_mb"), r.get("viewport")))
'
	fi
	echo "photos: $PHOTO_DIR"
fi
echo "logs: $GATE_LOG_DIR"
if [ "$FAILED" -eq 0 ]; then
	echo "GATE $MODE: PASS"
	exit 0
fi
echo "GATE $MODE: FAIL ($FAILED failed)"
exit 1
