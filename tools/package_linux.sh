#!/usr/bin/env bash
# Package the standalone Linux build of GridFall as one tar.gz (plus a .sha256) for a presenter machine.
#
# usage: tools/package_linux.sh [--skip-export] [--help]
# env:   EXPORT_DIR   where the export lands and the archive is written (default build)
#        GODOT        Godot binary, passed through to tools/export.sh (default godot)
#        GZIP_LEVEL   gzip level 1-9 (default 6; the pack is mostly compressed textures, so 9 buys little)
#        SOURCE_DATE_EPOCH  fixed file time inside the archive (default: the commit time, else 0)
#
# Runs tools/export.sh linux (release; --skip-export packages the export already in
# $EXPORT_DIR/linux/ instead), then writes
#   $EXPORT_DIR/gridfall-linux-x86_64-<VERSION>-<short git rev>.tar.gz
#   $EXPORT_DIR/gridfall-linux-x86_64-<VERSION>-<short git rev>.tar.gz.sha256
# holding, under one folder of that name: gridfall.x86_64, gridfall.pck, run-gridfall.sh (the launcher:
# windowed or fullscreen, Vulkan or OpenGL, with a fallback), README-linux.txt, LICENSE, VERSION and
# THIRD-PARTY-LICENSES/ (the licence texts of the models, characters and fonts in the pack).
# The same inputs give the same archive bytes. No key is read, printed or packed. The export log goes
# to $EXPORT_DIR/package-linux-export.log (printed only when the export fails).
set -u -o pipefail

usage() {
	awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2
	exit "${1:-2}"
}

SKIP_EXPORT=0
for arg in "$@"; do
	case "$arg" in
		--skip-export) SKIP_EXPORT=1 ;;
		-h|--help) usage 0 ;;
		*) echo "package_linux: unknown argument '$arg'" >&2; usage 2 ;;
	esac
done

cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"
EXPORT_DIR="${EXPORT_DIR:-build}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"
case "$GZIP_LEVEL" in [1-9]) ;; *) echo "package_linux: GZIP_LEVEL must be 1-9, got '$GZIP_LEVEL'" >&2; exit 2 ;; esac
mkdir -p "$EXPORT_DIR" || exit 2
EXPORT_DIR="$(cd "$EXPORT_DIR" && pwd)"
OUT_DIR="$EXPORT_DIR/linux"

for tool in tar gzip sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || { echo "package_linux: '$tool' not found" >&2; exit 2; }
done
tar --version 2>/dev/null | head -n1 | grep -q 'GNU tar' || { echo "package_linux: needs GNU tar" >&2; exit 2; }

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null)"
[ -n "$VERSION" ] || { echo "package_linux: VERSION is missing or empty" >&2; exit 2; }
REV="$(git rev-parse --short HEAD 2>/dev/null || true)"
[ -n "$REV" ] || REV="nogit"
EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || true)}"
[ -n "$EPOCH" ] || EPOCH=0
NAME="gridfall-linux-x86_64-$VERSION-$REV"
ARCHIVE="$EXPORT_DIR/$NAME.tar.gz"

if [ "$SKIP_EXPORT" -eq 0 ]; then
	echo "package: exporting the Linux release (log: $EXPORT_DIR/package-linux-export.log)" >&2
	if ! EXPORT_DIR="$EXPORT_DIR" tools/export.sh linux > "$EXPORT_DIR/package-linux-export.log" 2>&1; then
		tail -n 25 "$EXPORT_DIR/package-linux-export.log" >&2
		echo "package: export FAILED" >&2
		exit 1
	fi
fi
for f in gridfall.x86_64 gridfall.pck; do
	if [ ! -s "$OUT_DIR/$f" ]; then
		echo "package: missing $OUT_DIR/$f (run tools/export.sh linux first, or drop --skip-export)" >&2
		exit 1
	fi
done
# The export needs both of these in the pack: the audio buses (without default_bus_layout.tres the game
# plays silently) and the offline replay cache (without it the mayors have only the built-in planners).
for needle in default_bus_layout data/gmi_replay_cache.json; do
	grep -qaF "$needle" "$OUT_DIR/gridfall.pck" || echo "package: warning: gridfall.pck does not mention $needle" >&2
done

STAGE="$(mktemp -d "$EXPORT_DIR/.package-linux.XXXXXX")" || exit 2
trap 'rm -rf "$STAGE"' EXIT

cp LICENSE "$STAGE/LICENSE" || exit 1
printf '%s\nrev: %s\n' "$VERSION" "$REV" > "$STAGE/VERSION"

# Third-party notices travel with the program (Rocketbox MIT and the asset kits ask for it): the texts the
# repository keeps beside the models and fonts, under one folder.
TPL="$STAGE/THIRD-PARTY-LICENSES"
mkdir -p "$TPL/models" "$TPL/characters" "$TPL/real-models" "$TPL/fonts" || exit 1
for pair in models/LICENSES:models models/characters/LICENSES:characters models/real/LICENSES:real-models; do
	src="${pair%%:*}"
	if [ -d "$src" ]; then
		cp -R "$src/." "$TPL/${pair##*:}/" || exit 1
	else
		echo "package: warning: $src not found, its licence texts are not in the archive" >&2
	fi
done
if [ -f fonts/license.txt ]; then
	cp fonts/license.txt "$TPL/fonts/license.txt" || exit 1
else
	echo "package: warning: fonts/license.txt not found, its licence text is not in the archive" >&2
fi
find "$TPL" -type d -exec chmod 755 {} + && find "$TPL" -type f -exec chmod 644 {} +

cat > "$STAGE/run-gridfall.sh" <<'LAUNCHER'
#!/usr/bin/env bash
# GridFall launcher for Linux (x86_64). Sets no key and writes nothing; it only picks flags for the game.
#
# usage: ./run-gridfall.sh [--windowed | --fullscreen] [--renderer auto|vulkan|opengl3]
#                          [--orbit] [--offline] [--dry-run] [--help] [-- extra game arguments]
#
#   --windowed / --fullscreen   the window mode (default: windowed, 1600x900)
#   --renderer vulkan           Forward+ on Vulkan (FSR2 upscaling, SSAO, soft shadows)
#   --renderer opengl3          Compatibility on OpenGL 3.3 (bilinear scaling and MSAA instead of FSR2), for a
#                               GPU or driver without Vulkan 1.2
#   --renderer auto             (default) Vulkan when a Vulkan loader and driver are installed, else OpenGL
#                               3; if the game dies within 20 s on Vulkan it is started once more on OpenGL 3
#   --orbit                     start in the top-down city builder instead of on foot (there the sim runs
#                               whole ticks: about 250 ms stalls on a grown city; on foot it is sliced)
#   --offline                   never call GMI Cloud, whatever key is around (replay cache and built-in
#                               planners only): use it for a guaranteed offline run
#   --dry-run                   print the command and stop
#
# AI mayors live: export GMI_API_KEY=<your key> before this script, or paste it in the game (Esc,
# Settings, GMI Cloud). The game itself (not this script) also looks in ~/.factory/settings.json for a
# gmi-serving.com key when GMI_API_KEY is unset, so a machine that has that file goes live on its own
# unless you pass --offline. With no key the mayors replay recorded answers. See README-linux.txt.
set -u -o pipefail

usage() {
	awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
	exit "${1:-2}"
}

cd "$(dirname "$(readlink -f "$0")")" || exit 1
GAME="./gridfall.x86_64"

MODE=""
RENDERER="auto"
DRY=0
EXTRA=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--windowed) MODE="--windowed" ;;
		--fullscreen) MODE="--fullscreen" ;;
		--renderer)
			[ "$#" -ge 2 ] || { echo "run-gridfall: --renderer needs auto, vulkan or opengl3" >&2; exit 2; }
			RENDERER="$2"; shift ;;
		--renderer=*) RENDERER="${1#--renderer=}" ;;
		--orbit) export GRIDFALL_VIEW=orbit ;;
		--offline) export GRIDFALL_OFFLINE=1 ;;
		--dry-run) DRY=1 ;;
		-h|--help) usage 0 ;;
		--) shift; EXTRA=("$@"); break ;;
		*) echo "run-gridfall: unknown argument '$1'" >&2; usage 2 >&2 ;;
	esac
	shift
done
case "$RENDERER" in auto|vulkan|opengl3) ;; *) echo "run-gridfall: --renderer must be auto, vulkan or opengl3, got '$RENDERER'" >&2; exit 2 ;; esac

# A Vulkan loader plus at least one driver description. GRIDFALL_HAS_VULKAN=0|1 overrides the check.
has_vulkan() {
	if [ -n "${GRIDFALL_HAS_VULKAN:-}" ]; then
		[ "$GRIDFALL_HAS_VULKAN" = "1" ]
		return
	fi
	local loader=0 icd=0 d
	if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q 'libvulkan\.so\.1'; then loader=1; fi
	for d in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu; do
		[ -e "$d/libvulkan.so.1" ] && loader=1
	done
	for d in /usr/share/vulkan/icd.d /etc/vulkan/icd.d /usr/local/share/vulkan/icd.d "${HOME:-/nonexistent}/.local/share/vulkan/icd.d"; do
		compgen -G "$d/*.json" >/dev/null 2>&1 && icd=1
	done
	[ "$loader" -eq 1 ] && [ "$icd" -eq 1 ]
}

renderer_flags() {
	case "$1" in
		vulkan) echo "--rendering-driver vulkan --rendering-method forward_plus" ;;
		opengl3) echo "--rendering-driver opengl3 --rendering-method gl_compatibility" ;;
	esac
}

CHOSEN="$RENDERER"
if [ "$RENDERER" = "auto" ]; then
	if has_vulkan; then
		CHOSEN="vulkan"
	else
		CHOSEN="opengl3"
		echo "run-gridfall: no Vulkan loader or driver found, using the OpenGL 3 (Compatibility) renderer" >&2
	fi
fi

# shellcheck disable=SC2046  # the flag list is meant to split
build_cmd() {
	CMD=("$GAME" $(renderer_flags "$1"))
	[ -n "$MODE" ] && CMD+=("$MODE")
	[ "${#EXTRA[@]}" -gt 0 ] && CMD+=("${EXTRA[@]}")
	return 0
}
build_cmd "$CHOSEN"
if [ "$DRY" -eq 1 ]; then
	printf '%q ' "${CMD[@]}"; echo
	exit 0
fi
[ -x "$GAME" ] || { echo "run-gridfall: $GAME not found next to this script (keep gridfall.pck beside it)" >&2; exit 1; }

START="$(date +%s)"
"${CMD[@]}"
RC=$?
if [ "$RC" -ne 0 ] && [ "$RENDERER" = "auto" ] && [ "$CHOSEN" = "vulkan" ] && [ $(( $(date +%s) - START )) -lt 20 ]; then
	echo "run-gridfall: the game stopped within 20 s on Vulkan (exit $RC); trying the OpenGL 3 renderer once" >&2
	build_cmd opengl3
	exec "${CMD[@]}"
fi
exit "$RC"
LAUNCHER
chmod 755 "$STAGE/run-gridfall.sh"

cat > "$STAGE/README-linux.txt" <<'README'
GridFall for Linux (x86_64)
==========================

GridFall is a city builder where five AI mayors, each a different model on GMI Cloud, run one living
city. This is the standalone desktop build: the same game as the web demo, with a higher render scale, a
larger shadow atlas and full-size textures.

Requirements
------------
- 64-bit Linux on x86_64 with glibc 2.28 or newer (the program links nothing else; X11, Wayland, Vulkan
  and audio libraries are loaded when present).
- A GPU with Vulkan 1.2: Mesa RADV (AMD) or ANV (Intel), or NVIDIA driver 470 or newer. The loader
  (libvulkan1 / vulkan-icd-loader) must be installed.
  No Vulkan? Run ./run-gridfall.sh --renderer opengl3 (the OpenGL 3.3 Compatibility renderer: bilinear
  scaling and MSAA instead of Forward+'s FSR2 upscaling, so the picture differs a little).
- About 750 MB of disk after unpacking (the program is about 70 MB, the data pack gridfall.pck about
  650 MB), plus a shader cache in ~/.local/share/godot that grows as you play.
- No internet is needed to play.

Start
-----
    tar xzf gridfall-linux-x86_64-*.tar.gz
    cd gridfall-linux-x86_64-*/        # the trailing slash picks the folder, not the .tar.gz files beside it
    ./run-gridfall.sh                 # windowed, Vulkan if it is available
    ./run-gridfall.sh --fullscreen
    ./run-gridfall.sh --renderer opengl3
    ./run-gridfall.sh --offline       # never call GMI Cloud, whatever key is on the machine
    ./run-gridfall.sh --orbit         # the top-down city builder instead of on foot (on a grown city its sim
                                      # ticks can stall for about 250 ms; on foot the sim is sliced)
    ./run-gridfall.sh --help

Keep gridfall.pck in the same folder as gridfall.x86_64. The first launch compiles shaders, so the first
minute can stutter; the next launches are smoother. Verify the download with
    sha256sum -c gridfall-linux-x86_64-*.tar.gz.sha256

Controls
--------
Press Esc in the game for the pause menu; its Settings, Controls page lists every control. On foot:
WASD to walk, Shift to run, mouse to look, E to interact, F for a car, B for the build phone, M for
the map, Tab for the city overview, F5 to save, F9 to load. A gamepad also works.

AI mayors and your GMI key
--------------------------
No key is needed. With no key anywhere, the mayors replay answers recorded from GMI Cloud models and
fall back to built-in planners when a recording does not fit (offline mode).

Where the game looks for a key (in this order):
  1. GMI_API_KEY in the environment.
  2. If that is unset, the game itself reads the gmi-serving.com entry under "customModels" in
     ~/.factory/settings.json, if that file exists. The launcher does not touch it. A machine that has
     that file goes live without being asked.
For a run that is guaranteed offline, whatever key is around, use:   ./run-gridfall.sh --offline

To make the mayors think live, give the game your own GMI Cloud API key, either way:
  1. Before starting:   export GMI_API_KEY=<your key>    then   ./run-gridfall.sh
  2. In the game:       Esc, Settings, the GMI Cloud page, paste the key. It is kept in memory for
                        that session only (the desktop build does not store it); use way 1 to have
                        it every time.
The key goes only to GMI Cloud: api.gmi-serving.com for the mayors and console.gmicloud.ai for the poster
images. It is never logged. The launcher never reads or stores it.

Saves
-----
The city saves every morning and on quit, and continues next start. F5 saves at any time. Saves live in
~/.local/share/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim/ (gridfall_save.json,
the previous one as .bak). Esc, New city, twice, starts over.

Troubleshooting
---------------
- Black window or an immediate exit on Vulkan: ./run-gridfall.sh --renderer opengl3, and update the
  GPU driver (a current Mesa, or NVIDIA 470 or newer). "vulkaninfo --summary" lists the GPU drivers.
- No sound: the game uses PulseAudio or PipeWire (pipewire-pulse). Check that the system output works
  with another program, then start from a terminal and read the messages. Pass
  -- --audio-driver PulseAudio (or ALSA) to pick one.
- Wayland trouble (a frozen or tiny window): ./run-gridfall.sh -- --display-driver x11
- Stutter in the first minute: shader compilation; it settles on its own.

The source, the changelog and the web demo notes are in the project repository. The licence texts of the
models, characters and fonts are in THIRD-PARTY-LICENSES/.
README
chmod 644 "$STAGE/README-linux.txt" "$STAGE/LICENSE" "$STAGE/VERSION"

# One tar, deterministic: the order given here (directory contents sorted by name), fixed owner and time, no gzip name or time.
TMP_ARCHIVE="$ARCHIVE.part"
echo "package: writing $ARCHIVE" >&2
if ! tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" --mode='u+rwX,go+rX,go-w' \
	--transform "s,^,$NAME/," -cf - \
	-C "$OUT_DIR" gridfall.x86_64 gridfall.pck \
	-C "$STAGE" run-gridfall.sh README-linux.txt LICENSE VERSION THIRD-PARTY-LICENSES \
	| gzip -n "-$GZIP_LEVEL" > "$TMP_ARCHIVE"; then
	rm -f "$TMP_ARCHIVE"
	echo "package: tar failed" >&2
	exit 1
fi
mv -f "$TMP_ARCHIVE" "$ARCHIVE" || exit 1
( cd "$EXPORT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" ) || exit 1

echo "$ARCHIVE"
echo "$ARCHIVE.sha256"
ls -l "$ARCHIVE" >&2
cat "$ARCHIVE.sha256" >&2
echo "PACKAGE: PASS" >&2
