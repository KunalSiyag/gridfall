#!/usr/bin/env bash
# GridFall gate (docs/fp/S0-foundation.md §18).
#
# usage: tools/gate.sh quick|full|render [--only <step-substring>] [--keep]
# env:   GODOT (default: godot)   GATE_LOG_DIR (default: $GATE_TMP/gf-gate-<branch>-<UTC ts>)
#        DISPLAY (render only; default :1)   GATE_RETRIES (re-runs of a failed step; default 0)
#        GATE_TMP (lock, scratch dirs; default /tmp/claude-1000)   GATE_IMPORT_TIMEOUT (secs; default 900)
#
# A step that fails and then passes on a retry reports PASS(flaky), counts as a pass and is listed
# in $GATE_LOG_DIR/flaky.txt. Every run writes $GATE_LOG_DIR/results.json (step, result, rc, secs)
# and $GATE_LOG_DIR/pressure.tsv (per-attempt MemAvailable/Committed_AS/load/PSI snapshot).
# FAIL(no-token) -- a step that died without printing its verdict, the signature of a kill under
# load -- always retries once, even with GATE_RETRIES=0.
#
# A step also fails when its log holds an engine ERROR:/USER ERROR: line that no entry in
# tools/checks/baselines/engine_errors.txt covers (tools/checks/engine_errors.py does the scan);
# Godot prints those without failing the run, which hid real bugs (#67/#72).
#
# quick:  parse_all, the unit tests (sim, buildings, residents, expansion, construction, saves,
#          migration, determinism, image client, web), every tools/tests/fp_*_test.gd
# full:   quick + the two-seed soak (sim_soak_test) + orbit smoke + FP smoke (headless, heavy)
# render: FP photo tour + fp_bench (windowed, heavy); perf numbers are report-only
#
# Every Godot run gets a fresh XDG_DATA_HOME (the smokes save games), GRIDFALL_OFFLINE=1, no GMI
# key and a timeout. Heavy runs hold the machine-wide lock /tmp/claude-1000/gf-heavy.lock.
set -u -o pipefail

usage() {
	sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//' >&2
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
GATE_TMP="${GATE_TMP:-/tmp/claude-1000}"
GATE_RETRIES="${GATE_RETRIES:-0}"
GATE_IMPORT_TIMEOUT="${GATE_IMPORT_TIMEOUT:-900}"
case "$GATE_RETRIES" in ''|*[!0-9]*) GATE_RETRIES=0 ;; esac
LOCK="$GATE_TMP/gf-heavy.lock"
mkdir -p "$GATE_TMP"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || echo nobranch)"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GATE_LOG_DIR="${GATE_LOG_DIR:-$GATE_TMP/gf-gate-${BRANCH}-$(date -u +%Y%m%dT%H%M%SZ)}"
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
TRIES=()
RCS=()
FAILED=0

# Classifies a finished step from its exit code and log.
classify() {
	local rc="$1" log="$2" token="$3"
	if [ "$rc" -eq 124 ]; then
		echo "TIMEOUT"
	elif grep -qE 'SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|No loader found' "$log"; then
		echo "FAIL(script-error)"
	elif ! grep -qF -- "$token" "$log"; then
		echo "FAIL(no-token)"
	elif [ "$rc" -ne 0 ]; then
		echo "FAIL(exit=$rc)"
	else
		python3 tools/checks/engine_errors.py "$log" >/dev/null 2>&1
		case $? in
			0) echo "PASS" ;;
			1) echo "FAIL(engine-error)" ;;
			*) echo "FAIL(engine-check)" ;; # a broken checker is not a game error
		esac
	fi
}

is_pass() {
	case "$1" in PASS|"PASS(flaky)") return 0 ;; esac
	return 1
}

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
	local t0 rc res first="" attempt=0 xdg rcs=""
	t0=$(date +%s)
	while :; do
		# Every attempt gets a fresh XDG_DATA_HOME, so a retry never sees the failed run's saves.
		xdg="$(mktemp -d "$GATE_TMP/gf-xdg.XXXXXX")"
		XDG_DIRS+=("$xdg")
		# A hung step gets SIGSEGV, not SIGTERM: Godot's crash handler then writes its C++ and
		# GDScript backtraces into the step log (timeout still exits 124).
		local cmd=(env -u GMI_API_KEY -u GRIDFALL_RECORD -u GRIDFALL_VIEW -u GRIDFALL_SPEED -u GRIDFALL_HOUR -u GRIDFALL_RESIDENTS
			"XDG_DATA_HOME=$xdg" GRIDFALL_OFFLINE=1 "${envs[@]+"${envs[@]}"}" timeout -s SEGV -k 30 "$tmo" "$GODOT" "$@")
		if [ "$heavy" = "1" ]; then
			cmd=(flock -w 3600 "$LOCK" "${cmd[@]}")
		fi
		printf '%-28s ...\r' "$name" >&2
		# Per-attempt pressure snapshot: when a step dies silently under load (the no-token
		# mass deaths), this is the only record of what the box looked like at spawn time.
		printf '%s\t%s\tattempt=%d\tMemAvailable=%s\tCommitted_AS=%s\tload1=%s\tpsi_mem=%s\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$name" "$((attempt + 1))" \
			"$(awk '/^MemAvailable/{print $2}' /proc/meminfo)" \
			"$(awk '/^Committed_AS/{print $2}' /proc/meminfo)" \
			"$(cut -d' ' -f1 /proc/loadavg)" \
			"$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null)" >>"$GATE_LOG_DIR/pressure.tsv" 2>/dev/null || true
		"${cmd[@]}" >"$log" 2>&1
		rc=$?
		rcs="${rcs:+$rcs, }$rc"
		res="$(classify "$rc" "$log" "$token")"
		if [ "$res" = "FAIL(no-token)" ]; then
			# Godot fully buffers stdout to a file: a killed or aborted step loses every
			# buffered line, and a shell-level spawn failure never reaches the log at all.
			printf 'gate: step died with rc=%s and no verdict (killed, aborted, or the spawn itself failed); see pressure.tsv\n' "$rc" >>"$log"
		fi
		attempt=$((attempt + 1))
		[ "$res" = "PASS" ] && break
		[ -z "$first" ] && first="$res"
		# A no-token death is an environmental kill, not a verdict: always retry it once,
		# even with GATE_RETRIES=0. A retried pass still lands in flaky.txt as PASS(flaky).
		local max_tries="$GATE_RETRIES"
		[ "$res" = "FAIL(no-token)" ] && [ "$max_tries" -lt 1 ] && max_tries=1
		[ "$attempt" -gt "$max_tries" ] && break
		mv -f "$log" "$GATE_LOG_DIR/$name.try$attempt.log"
		printf '%-28s %s, retrying (%d/%d)\n' "$name" "$res" "$attempt" "$max_tries" >&2
	done
	case "$res" in
		"FAIL(engine-error)"|"FAIL(engine-check)") python3 tools/checks/engine_errors.py "$log" >&2 || true ;;
	esac
	if [ "$res" = "PASS" ] && [ "$attempt" -gt 1 ]; then
		res="PASS(flaky)"
		printf '%s\t%s\t%s\t%s\n' "$name" "$first" "$attempt" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$GATE_LOG_DIR/flaky.txt"
	fi
	local secs=$(( $(date +%s) - t0 ))
	NAMES+=("$name"); RESULTS+=("$res"); SECS+=("$secs"); LOGS+=("$log"); TRIES+=("$attempt"); RCS+=("${rcs:-$rc}")
	is_pass "$res" || FAILED=$((FAILED + 1))
	printf '%-28s %s (%ss)\n' "$name" "$res" "$secs" >&2
	return 0
}

# Overrides a recorded result (used when a step's own checks go beyond its token).
set_last_result() {
	local n=$(( ${#RESULTS[@]} - 1 ))
	[ "$n" -ge 0 ] || return 0
	if is_pass "${RESULTS[$n]}" && ! is_pass "$1"; then FAILED=$((FAILED + 1)); fi
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
	run_step import "" "$GATE_IMPORT_TIMEOUT" 1 -- -- --headless --path . --import
	ONLY="$only_saved"
	if is_pass "${RESULTS[$(( ${#RESULTS[@]} - 1 ))]}"; then
		touch "$STAMP"
	fi
fi

if [ "$MODE" = "quick" ] || [ "$MODE" = "full" ]; then
	run_step parse_all "PARSE_ALL: PASS" 180 0 -- -- --headless --path . -s tools/tests/parse_all.gd
	for t in sim_test buildings_test residents_test expansion_test construction_test save_test save_migration_test save_versions_test sim_determinism_test sim_tick_budget_test ai_image_client_test web_test web_pacing_test pack_loader_test web_pack_stream_test; do
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
	run_step sim_soak_test "SIM_SOAK_TEST: PASS" 420 1 -- -- --headless --path . -s tools/tests/sim_soak_test.gd
	run_step orbit_smoke "GRIDFALL_SMOKE: PASS" 400 1 -- GRIDFALL_SMOKE_TEST=1 -- --headless --path .
	run_step fp_smoke "FP_SMOKE: PASS" 400 1 -- GRIDFALL_FP_SMOKE=1 -- --headless --path .
fi

PHOTO_DIR="$GATE_LOG_DIR/photos"
BENCH_DIR="$GATE_LOG_DIR/bench"
if [ "$MODE" = "render" ]; then
	DISP="${DISPLAY:-:1}"
	before=${#RESULTS[@]}
	run_step fp_photo "FP_PHOTO: DONE" 400 1 -- "DISPLAY=$DISP" "GRIDFALL_FP_PHOTO_DIR=$PHOTO_DIR" GRIDFALL_PHOTO_DAYS=6 -- --path . --resolution 1600x900 --audio-driver Dummy
	if [ ${#RESULTS[@]} -gt "$before" ] && is_pass "${RESULTS[$before]}"; then
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
	if [ ${#RESULTS[@]} -gt "$before" ] && is_pass "${RESULTS[$before]}"; then
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

# Machine-readable results for CI artifacts, tools/checks/build_timing.py and flaky_report.py.
{
	printf '{\n "mode": "%s",\n "branch": "%s",\n "commit": "%s",\n "started": "%s",\n "finished": "%s",\n' \
		"$MODE" "$BRANCH" "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "$STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf ' "retries": %s,\n "failed": %s,\n "result": "%s",\n "steps": [' "$GATE_RETRIES" "$FAILED" "$([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)"
	sep=""
	for i in "${!NAMES[@]}"; do
		printf '%s\n  {"step": "%s", "result": "%s", "rcs": [%s], "secs": %s, "attempts": %s, "log": "%s"}' \
			"$sep" "${NAMES[$i]}" "${RESULTS[$i]}" "${RCS[$i]:--1}" "${SECS[$i]}" "${TRIES[$i]}" "${LOGS[$i]}"
		sep=","
	done
	printf '\n ]\n}\n'
} >"$GATE_LOG_DIR/results.json"
echo "results: $GATE_LOG_DIR/results.json"
if [ "$FAILED" -eq 0 ]; then
	echo "GATE $MODE: PASS"
	exit 0
fi
echo "GATE $MODE: FAIL ($FAILED failed)"
exit 1
