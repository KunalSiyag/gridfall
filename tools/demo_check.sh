#!/usr/bin/env bash
# GridFall demo check: is a deployed web instance ready for a player with a key?
#
# usage: tools/demo_check.sh [BASE_URL ...]     (default: the two known instances below)
# env:   DEMO_CHECK_TIMEOUT   seconds per request (default 30)
#        DEMO_CHECK_BUILD     0 skips reading the .pck for the build marker (default 1); the run says so
#                             on its last line
#        DEMO_CHECK_BUILD_MARKER   the text only a build with the browser-header fix holds
#                             (default gmi_web_safe_headers; change it if that flag is ever removed)
#        DEMO_CHECK_BUILD_TIMEOUT  seconds for the .pck download (default 240; the .pck is 88-106 MB on
#                             the wire, so below about 3.5 Mbit/s raise it or the build stays unverified)
#        GATE_TMP             where tools/gate.sh keeps its logs (default /tmp/claude-1000)
#        GMI_PREFLIGHT_URL    test hook: the URL the CORS preflight goes to (default GMI's chat URL)
#
# Read-only: curl only (GET/HEAD, and one key-free OPTIONS per instance to GMI), no key is read or
# sent, nothing is written outside stdout. For each instance it checks
#   - /healthz answers 200 "ok";
#   - the loader page carries COOP same-origin, COEP require-corp and Cache-Control no-cache;
#   - every file the page names comes back Brotli-compressed (a precompressed .pck/.wasm sidecar),
#     the .pck is immutable, and the compressed first-load bytes (the sum of their sizes); a .pck,
#     .wasm or .js the page names that does not answer 200 fails (the game cannot start);
#   - the BUILD: the .pck is read (about the size of a first load) for the browser-header fix. An
#     image built before it still sends User-Agent, X-Request-ID and X-Trace-ID, which GMI's CORS
#     preflight does not allow, so every live call from a browser is blocked whatever the next
#     check says. That is a FAIL. A pack that could not be read (a slow link, a timeout) leaves the
#     build unverified, and the run then ends INCOMPLETE (exit 1), never PASS, because the one
#     image this tool exists to catch would pass every other check; DEMO_CHECK_BUILD=0 is the
#     operator's explicit skip and ends "NO BUILD CHECK" (exit 0);
#   - the CORS preflight api.gmi-serving.com answers for the headers the web client really sends
#     (Authorization and Content-Type, see GmiClient.request_headers): OK or BLOCKED. This checks
#     GMI's side only: it says nothing about what an instance's build sends (the BUILD check does).
#     A browser refuses every live call when the preflight does not allow a header, and the game
#     then runs silently on its replay cache while the player believes it is live.
# Then it prints the git revision and how old the newest tools/gate.sh result is.
# Last line: DEMO_CHECK: PASS | FAIL (n) | INCOMPLETE (build not verified) | NO BUILD CHECK (skipped).
# Exit: 0 every check passed (or the build check was skipped on request), 1 at least one failed or
# the build could not be verified, 2 bad arguments.
set -u -o pipefail

# The instances docs/runbooks/web-deploy.md lists as running (2026-11-03): the new build and the
# older one left up for comparison.
DEFAULT_INSTANCES=(
	"https://ct-b22afc4d-cbdb-45e4-b3da-e209d09593fa-web.caas-us1.gmicloud.ai"
	"https://ct-1ff7949c-bd38-4939-b13c-4a0638d82bec-web.caas-us1.gmicloud.ai"
)
# The request headers the web build puts on a GMI call (a browser adds its own safelisted ones).
# Keep in step with GmiClient.request_headers(web = true); tools/tests/fp_keyflow_test.gd checks it.
WEB_REQUEST_HEADERS="authorization,content-type"
PREFLIGHT_URL="${GMI_PREFLIGHT_URL:-https://api.gmi-serving.com/v1/chat/completions}"
TIMEOUT="${DEMO_CHECK_TIMEOUT:-30}"
GATE_TMP="${GATE_TMP:-/tmp/claude-1000}"
CHECK_BUILD="${DEMO_CHECK_BUILD:-1}"
# The flag that switches the web-safe headers is in the pack's data/feature_flags.json (plain JSON),
# so its name is found in a build that has the fix and in no build older than it.
BUILD_MARKER="${DEMO_CHECK_BUILD_MARKER:-gmi_web_safe_headers}"
BUILD_TIMEOUT="${DEMO_CHECK_BUILD_TIMEOUT:-240}"
case "$TIMEOUT" in '' | *[!0-9]*) TIMEOUT=30 ;; esac
case "$BUILD_TIMEOUT" in '' | *[!0-9]*) BUILD_TIMEOUT=240 ;; esac
PCK_PATH=""

FAILS=0
# Instances whose build could not be read (a failed or timed-out download, no .pck to read) and
# instances whose build check was skipped on request (DEMO_CHECK_BUILD=0). Neither is a pass.
UNVERIFIED=0
SKIPPED=0

usage() {
	# -h/--help exits 0 and prints to stdout; a bad argument exits 2 and prints to stderr.
	if [ "${1:-2}" -eq 0 ]; then
		sed -n '2p;4,13p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
	fi
	sed -n '2p;4,13p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
fail() {
	printf '  FAIL  %s\n' "$*"
	FAILS=$((FAILS + 1))
}

# hdr <name> <header block>: the value of one response header, any case, "" when absent.
hdr() {
	printf '%s\n' "$2" | tr -d '\r' | awk -v want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" '
		{ i = index($0, ":") }
		i > 0 && tolower(substr($0, 1, i - 1)) == want { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); last = v }
		END { print last }'
}

# status_of <header block>: the HTTP status code of the first status line.
status_of() { printf '%s\n' "$1" | tr -d '\r' | awk '/^HTTP\// { print $2; exit }'; }

# lower <text>: lower case.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# get <curl args...>: stdout of a read-only curl; prints nothing when the request fails.
get() { curl --silent --max-time "$TIMEOUT" "$@" 2>/dev/null; }

# mb <bytes>: megabytes (10^6) with one decimal.
mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'; }

# assets_of <loader page>: the files the page itself names (fileSizes keys, src and href values that
# are not absolute, an anchor or inline), one per line, without a leading slash.
assets_of() {
	{
		printf '%s\n' "$1" | grep -oE '"[^"]+\.(pck|wasm|js|json|html|png)":[0-9]+' | sed -E 's/^"([^"]+)":.*/\1/'
		printf '%s\n' "$1" | grep -oE '(src|href)="[^"]+"' | sed -E 's/^(src|href)="([^"]*)"$/\2/'
	} | grep -vE '^(https?:|data:|#|//)' | sed 's|^/||' | grep -v '^$' | sort -u
}

check_healthz() {
	local base="$1" out code body shown
	out="$(get --write-out '\n%{http_code}' "$base/healthz")"
	code="${out##*$'\n'}"
	body="${out%$'\n'*}"
	# Trailing blanks and line ends are not part of the answer ("ok\n" is as good as "ok").
	body="$(printf '%s' "$body" | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
	if [ "$code" = "200" ] && [ "$body" = "ok" ]; then
		ok "/healthz 200 ok"
	elif [ -z "$code" ] || [ "$code" = "000" ]; then
		fail "/healthz: no answer (instance down, wrong URL or no network)"
	elif [ "$code" = "200" ]; then
		shown="$(printf '%s' "$body" | tr -c '[:print:]' '?' | cut -c 1-40)"
		fail "/healthz answered 200 with '${shown:-nothing}' (want the body: ok)"
	else
		fail "/healthz answered $code (want 200 ok)"
	fi
}

# check_loader <base>: the loader page's headers; sets LOADER_BODY for the asset checks.
check_loader() {
	local base="$1" raw head status v
	LOADER_BODY=""
	raw="$(get --include "$base/")"
	head="$(printf '%s\n' "$raw" | tr -d '\r' | awk '/^$/ { exit } { print }')"
	LOADER_BODY="$(printf '%s\n' "$raw" | tr -d '\r' | awk 'p { print } /^$/ && !p { p = 1 }')"
	status="$(status_of "$head")"
	if [ "$status" != "200" ]; then
		fail "loader page / answered ${status:-nothing} (want 200)"
		return
	fi
	ok "loader page 200"
	v="$(hdr cross-origin-opener-policy "$head")"
	if [ "$v" = "same-origin" ]; then
		ok "COOP same-origin"
	else
		fail "COOP is '${v:-missing}' (want same-origin; threads will not boot)"
	fi
	v="$(hdr cross-origin-embedder-policy "$head")"
	if [ "$v" = "require-corp" ]; then
		ok "COEP require-corp"
	else
		fail "COEP is '${v:-missing}' (want require-corp; threads will not boot)"
	fi
	v="$(hdr cache-control "$head")"
	case "$v" in
		*no-cache*) ok "loader Cache-Control no-cache" ;;
		*) fail "loader Cache-Control is '${v:-missing}' (want no-cache, or a redeploy will not reach returning players)" ;;
	esac
}

# check_assets <base>: Brotli sidecars, immutable releases and the compressed first-load bytes.
check_assets() {
	local base="$1" path head enc cache len total=0 files=0 unknown=0 pck_named=0
	PCK_PATH=""
	if [ -z "$LOADER_BODY" ]; then
		fail "no loader page to read the asset list from"
		return
	fi
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		case "$path" in
			*.pck)
				pck_named=1
				[ -n "$PCK_PATH" ] || PCK_PATH="$path"
				;;
		esac
		head="$(get --head --header 'Accept-Encoding: br' "$base/$path")"
		if [ "$(status_of "$head")" != "200" ]; then
			case "$path" in
				*.pck | *.wasm | *.js)
					# The page names it and the game cannot start without it.
					fail "$path: HTTP $(status_of "$head" | sed 's/^$/none/') (the page names it; the game cannot start without it)"
					;;
				*)
					# A name in the page that is not a real file (a template placeholder) is only worth a note.
					warn "$path: HTTP $(status_of "$head" | sed 's/^$/none/') (not counted)"
					;;
			esac
			continue
		fi
		enc="$(lower "$(hdr content-encoding "$head")")"
		cache="$(hdr cache-control "$head")"
		len="$(hdr content-length "$head")"
		files=$((files + 1))
		case "$len" in
			'' | *[!0-9]*) unknown=$((unknown + 1)) ;;
			*) total=$((total + len)) ;;
		esac
		case "$path" in
			*.pck | *.wasm)
				if [ "$enc" = "br" ]; then
					ok "$path content-encoding br, ${len:-?} bytes"
				else
					fail "$path content-encoding '${enc:-identity}' (want br: the first load would be about twice as big)"
				fi
				case "$cache" in
					*immutable*) : ;;
					*) fail "$path cache-control '${cache:-missing}' (want public, max-age=31536000, immutable)" ;;
				esac
				;;
		esac
	done < <(assets_of "$LOADER_BODY")
	if [ "$pck_named" -eq 0 ]; then
		fail "the loader page names no .pck (is this a GridFall web build?)"
	fi
	if [ "$unknown" -gt 0 ]; then
		warn "$unknown file(s) gave no content-length: the total is a lower bound"
	fi
	ok "first load, compressed (Brotli): $(mb "$total") MB in $files files"
}

# check_build <base>: does the deployed pack hold the browser-header fix? The .pck is streamed through
# grep, which stops at the first hit. Found = ok; read to the end without it = the image predates the
# fix and a browser would block every live call = FAIL; a failed download = a warning here and an
# INCOMPLETE verdict at the end (the build is unverified, which is not a pass).
check_build() {
	local base="$1"
	local -a rcs
	if [ "$CHECK_BUILD" = "0" ]; then
		warn "build: not read (DEMO_CHECK_BUILD=0); whether this image sends the browser-safe headers is not verified"
		SKIPPED=$((SKIPPED + 1))
		return
	fi
	if [ -z "$PCK_PATH" ]; then
		warn "build: no .pck to read; whether this image sends the browser-safe headers is not verified"
		UNVERIFIED=$((UNVERIFIED + 1))
		return
	fi
	curl --silent --fail --compressed --max-time "$BUILD_TIMEOUT" "$base/$PCK_PATH" 2>/dev/null | grep -a -q -F -- "$BUILD_MARKER"
	rcs=("${PIPESTATUS[@]}")
	if [ "${rcs[1]}" -eq 0 ]; then
		ok "build: the pack holds '$BUILD_MARKER': this build's code sends only Authorization and Content-Type from a browser (read from the pack, not seen in a browser)"
	elif [ "${rcs[0]}" -eq 0 ] && [ "${rcs[1]}" -eq 1 ]; then
		fail "build: the pack has no '$BUILD_MARKER': this image predates the browser-header fix and still sends User-Agent, X-Request-ID and X-Trace-ID, which GMI's preflight does not allow, so EVERY live call from a browser is blocked and the game runs on its replay cache. An image this old also has no Test button on its GMI Cloud page. Rebuild and redeploy from a commit that has the fix."
	else
		warn "build: could not read $PCK_PATH (curl exit ${rcs[0]}); whether this image sends the browser-safe headers is not verified (a slow link: raise DEMO_CHECK_BUILD_TIMEOUT)"
		UNVERIFIED=$((UNVERIFIED + 1))
	fi
}

# check_cors <base>: the key-free preflight, with this instance as the Origin and the headers the
# web client sends. Allow-Headers must list each one (a "*" never covers Authorization).
check_cors() {
	local base="$1" raw status allow_origin allow_headers allow_methods missing="" h list wild=0
	local -a wanted
	raw="$(get --include --request OPTIONS "$PREFLIGHT_URL" \
		--header "Origin: $base" \
		--header "Access-Control-Request-Method: POST" \
		--header "Access-Control-Request-Headers: $WEB_REQUEST_HEADERS")"
	status="$(status_of "$raw")"
	if [ -z "$status" ]; then
		fail "CORS preflight: no answer from ${PREFLIGHT_URL%%/v1/*} (no network?)"
		return
	fi
	allow_origin="$(hdr access-control-allow-origin "$raw")"
	allow_headers="$(hdr access-control-allow-headers "$raw")"
	allow_methods="$(hdr access-control-allow-methods "$raw")"
	printf '        preflight HTTP %s  Allow-Origin: %s\n        Allow-Headers: %s\n        Allow-Methods: %s\n' \
		"$status" "${allow_origin:-none}" "${allow_headers:-none}" "${allow_methods:-none}"
	list=",$(lower "$allow_headers" | tr -d ' \t'),"
	case "$list" in *,\*,*) wild=1 ;; esac
	IFS=',' read -r -a wanted <<<"$WEB_REQUEST_HEADERS"
	for h in "${wanted[@]}"; do
		case "$list" in *",$h,"*) continue ;; esac
		# A "*" in Allow-Headers covers every header except Authorization, which must be named.
		if [ "$wild" -eq 1 ] && [ "$h" != "authorization" ]; then continue; fi
		missing="$missing $h"
	done
	case "$status" in 2*) : ;; *) missing="$missing (preflight status $status)" ;; esac
	case "$allow_origin" in
		'*' | "$base") : ;;
		*) missing="$missing (Allow-Origin ${allow_origin:-none})" ;;
	esac
	case "$(lower "$allow_methods")" in
		*post* | *'*'*) : ;;
		*) missing="$missing (POST not allowed)" ;;
	esac
	if [ -z "$missing" ]; then
		ok "CORS preflight OK: GMI's preflight allows ($WEB_REQUEST_HEADERS) from this origin (GMI's side only: see the build check for what this image sends; no browser call was observed)"
	else
		fail "CORS preflight BLOCKED, not allowed:$missing. Every live call from the browser would fail and the game would run on its replay cache."
	fi
}

check_instance() {
	local base="${1%/}"
	printf '\n== %s\n' "$base"
	check_healthz "$base"
	check_loader "$base"
	check_assets "$base"
	check_build "$base"
	check_cors "$base"
}

# age_text <seconds>: "5 min", "2 h 14 min" or "3 d 4 h".
age_text() {
	awk -v s="$1" 'BEGIN {
		if (s < 0) s = 0
		if (s < 3600) printf "%d min", s / 60
		else if (s < 86400) printf "%d h %d min", s / 3600, (s % 3600) / 60
		else printf "%d d %d h", s / 86400, (s % 86400) / 3600 }'
}

# mtime_of <file>: seconds since the epoch (GNU or BSD stat).
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

report_repo() {
	local root rev head_full branch dirty newest="" newest_ts=0 f ts now gate_commit gate_result gate_mode
	root="$(cd "$(dirname "$0")/.." && pwd)" || return
	printf '\n== this checkout\n'
	# GIT_OPTIONAL_LOCKS=0: a plain `git status` refreshes the index's stat cache and writes it (and
	# takes index.lock), which would make this script write into the checkout and race another git.
	export GIT_OPTIONAL_LOCKS=0
	rev="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
	head_full="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo none)"
	branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
	dirty=""
	if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then dirty=" (uncommitted changes)"; fi
	printf '  git revision %s on %s%s\n' "$rev" "$branch" "$dirty"
	for f in "$GATE_TMP"/gf-gate-*/results.json; do
		[ -f "$f" ] || continue
		ts="$(mtime_of "$f")"
		case "$ts" in '' | *[!0-9]*) continue ;; esac
		if [ "$ts" -gt "$newest_ts" ]; then
			newest_ts="$ts"
			newest="$f"
		fi
	done
	if [ -z "$newest" ]; then
		warn "no gate result under $GATE_TMP/gf-gate-*/results.json (run tools/gate.sh quick)"
		return
	fi
	now="$(date +%s)"
	gate_mode="$(sed -n 's/^ *"mode": *"\([^"]*\)".*/\1/p' "$newest" | head -n 1)"
	gate_result="$(sed -n 's/^ *"result": *"\([^"]*\)".*/\1/p' "$newest" | head -n 1)"
	gate_commit="$(sed -n 's/^ *"commit": *"\([^"]*\)".*/\1/p' "$newest" | head -n 1)"
	printf '  newest gate result: %s %s, %s ago (%s)\n' "${gate_mode:-?}" "${gate_result:-?}" "$(age_text $((now - newest_ts)))" "$newest"
	if [ -n "$gate_commit" ] && [ "$gate_commit" = "$head_full" ]; then
		if [ -n "$dirty" ]; then
			# The gate records the commit, not the working tree: edits made since are not covered.
			warn "the gate ran on this revision, but the tree has uncommitted changes the result may not cover"
		else
			ok "the gate ran on this revision"
		fi
	else
		warn "the gate ran on ${gate_commit:0:7}, this checkout is at $rev"
	fi
	if [ "$gate_result" != "PASS" ]; then
		warn "the newest gate result is ${gate_result:-unknown}, not PASS"
	fi
}

main() {
	local arg
	for arg in "$@"; do
		case "$arg" in
			-h | --help) usage 0 ;;
			http://* | https://*) : ;;
			*) printf 'demo_check: not a URL: %s\n' "$arg" >&2; usage ;;
		esac
	done
	if ! command -v curl >/dev/null 2>&1; then
		printf 'demo_check: curl is required\n' >&2
		exit 2
	fi
	local instances=("$@")
	[ "$#" -gt 0 ] || instances=("${DEFAULT_INSTANCES[@]}")
	printf 'GridFall demo check (read-only, no key used)\n'
	if [ "$#" -eq 0 ]; then
		printf 'no URL given: checking the two default instances (the 2026-11-03 pair). After a deploy pass the new one: tools/demo_check.sh <url>\n'
	fi
	local inst
	for inst in "${instances[@]}"; do
		check_instance "$inst"
	done
	report_repo
	printf '\n'
	if [ "$FAILS" -gt 0 ]; then
		if [ "$UNVERIFIED" -gt 0 ]; then
			printf 'The build was also not verified on %d instance(s).\n' "$UNVERIFIED"
		fi
		printf 'DEMO_CHECK: FAIL (%d check(s))\n' "$FAILS"
		exit 1
	elif [ "$UNVERIFIED" -gt 0 ]; then
		# The image this tool exists to catch (one from before the header fix) passes every check but the
		# build one, so a build that could not be read must not end in PASS.
		printf 'DEMO_CHECK: INCOMPLETE (the build was not verified on %d instance(s): an image from before the browser-header fix would pass every other check; rerun with a longer DEMO_CHECK_BUILD_TIMEOUT)\n' "$UNVERIFIED"
		exit 1
	elif [ "$SKIPPED" -gt 0 ]; then
		printf 'DEMO_CHECK: NO BUILD CHECK (skipped on request with DEMO_CHECK_BUILD=0; every other check passed, but whether the image sends the browser-safe headers is not verified)\n'
	else
		printf 'DEMO_CHECK: PASS (static checks only: the keyed call is verified by the in-game Test button)\n'
	fi
}

main "$@"
