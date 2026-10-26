#!/usr/bin/env bash
# Export GridFall release builds with the presets in export_presets.cfg.
#
# usage: tools/export.sh <linux|windows|web|all> [--debug]
# env:   GODOT (default: godot)   EXPORT_DIR (default: build)   GATE_TMP (lock dir, default /tmp/claude-1000)
#
# Writes build/linux/gridfall.x86_64 (+ .pck) and build/windows/gridfall.exe (+ .pck); web builds
# build/web/index.html (+ .js, .wasm, .pck) for deploy/web/. Needs the Godot export templates
# matching .godot-version in ~/.local/share/godot/export_templates/<ver>/. The export imports the
# project first when needed; it holds the heavy-run lock like the gate.
set -u -o pipefail

usage() {
	sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

TARGET="${1:-}"
MODE="--export-release"
[ "${2:-}" = "--debug" ] && MODE="--export-debug"
case "$TARGET" in
	linux|windows|web|all) ;;
	*) usage ;;
esac

cd "$(dirname "$0")/.." || exit 2
GODOT="${GODOT:-godot}"
EXPORT_DIR="${EXPORT_DIR:-build}"
GATE_TMP="${GATE_TMP:-/tmp/claude-1000}"
mkdir -p "$GATE_TMP"
LOCK="$GATE_TMP/gf-heavy.lock"
VER="$(tr -d '[:space:]' < .godot-version)"
TPL_DIR="${GODOT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/$VER}"
DL_VER="${VER%.stable}-stable"

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "export: Godot binary '$GODOT' not found (set GODOT=/path/to/godot)" >&2
	exit 2
fi
have="$("$GODOT" --version 2>/dev/null | head -n1)"
case "$have" in
	"$VER"*) ;;
	*) echo "export: warning: $GODOT is '$have', .godot-version wants $VER" >&2 ;;
esac

need_tpl() {
	case "$1" in
		linux) echo "linux_release.x86_64" ;;
		windows) echo "windows_release_x86_64.exe" ;;
		web) echo "web_nothreads_release.zip" ;;  # the Web preset exports the no-threads variant
	esac
}
missing=0
targets=("$TARGET")
[ "$TARGET" = "all" ] && targets=(linux windows)
for t in "${targets[@]}"; do
	f="$(need_tpl "$t")"
	[ "$MODE" = "--export-debug" ] && f="${f/release/debug}"
	if [ ! -f "$TPL_DIR/$f" ]; then
		echo "export: missing template $TPL_DIR/$f" >&2
		missing=1
	fi
done
if [ "$missing" -eq 1 ]; then
	cat >&2 <<EOF_HELP
export: install the $VER export templates (a 1.3 GB download; the x86_64 desktop and web ones unpack to ~500 MB):
  curl -fLO https://github.com/godotengine/godot/releases/download/$DL_VER/Godot_v${DL_VER}_export_templates.tpz
  mkdir -p "$TPL_DIR"
  unzip -j -o Godot_v${DL_VER}_export_templates.tpz templates/version.txt \\
    'templates/linux_*.x86_64' 'templates/windows_*_x86_64.exe' 'templates/windows_*_x86_64_console.exe' \\
    'templates/web_*.zip' -d "$TPL_DIR"
or in the editor: Editor > Manage Export Templates > Download and Install.
EOF_HELP
	exit 3
fi

preset_of() {
	case "$1" in
		linux) echo "Linux" ;;
		windows) echo "Windows Desktop" ;;
		web) echo "Web" ;;
	esac
}
out_of() {
	case "$1" in
		linux) echo "$EXPORT_DIR/linux/gridfall.x86_64" ;;
		windows) echo "$EXPORT_DIR/windows/gridfall.exe" ;;
		web) echo "$EXPORT_DIR/web/index.html" ;;
	esac
}
rc=0
for t in "${targets[@]}"; do
	out="$(out_of "$t")"
	mkdir -p "$(dirname "$out")"
	echo "export: $t -> $out" >&2
	if [ "$t" = "web" ]; then
		flock -w 3600 "$LOCK" env -u GMI_API_KEY python3 tools/web_export.py \
			--root "$PWD" --output "$(dirname "$out")" --godot "$GODOT" --mode="$MODE"
		export_rc=$?
	else
		flock -w 3600 "$LOCK" env -u GMI_API_KEY "$GODOT" --headless --path . "$MODE" "$(preset_of "$t")" "$out"
		export_rc=$?
	fi
	if [ "$export_rc" -ne 0 ]; then
		echo "export: $t FAILED" >&2
		rc=1
		continue
	fi
	if [ ! -s "$out" ]; then
		echo "export: $t produced no $out" >&2
		rc=1
		continue
	fi
	ls -l "$(dirname "$out")" >&2
done
[ "$rc" -eq 0 ] && echo "EXPORT: PASS" || echo "EXPORT: FAIL"
exit "$rc"
