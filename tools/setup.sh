#!/usr/bin/env bash
# One-command developer setup for GridFall.
#
# usage: tools/setup.sh [--no-import]
# env:   GODOT (default: godot)   VENV (default: ~/.venvs/gridfall-tools)
#
# Creates the Python venv with the pinned tools (tools/requirements-dev.txt), installs the
# pre-commit hooks, checks the Godot version against .godot-version and runs the first asset
# import (several minutes; skipped with --no-import or when .godot/ already exists).
set -euo pipefail

cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
VENV="${VENV:-$HOME/.venvs/gridfall-tools}"
IMPORT=1
[ "${1:-}" = "--no-import" ] && IMPORT=0

if [ ! -x "$VENV/bin/python" ]; then
	echo "setup: creating venv $VENV"
	python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r tools/requirements-dev.txt
"$VENV/bin/pre-commit" install --hook-type pre-commit --hook-type pre-push

want="$(tr -d '[:space:]' < .godot-version)"
if command -v "$GODOT" >/dev/null 2>&1; then
	have="$("$GODOT" --version 2>/dev/null | head -n1)"
	case "$have" in
		"$want"*) echo "setup: Godot $have" ;;
		*) echo "setup: warning: $GODOT is '$have', .godot-version wants $want" >&2 ;;
	esac
	if [ "$IMPORT" -eq 1 ] && [ ! -d .godot/imported ]; then
		echo "setup: importing assets (first run takes several minutes)"
		env -u GMI_API_KEY GRIDFALL_OFFLINE=1 "$GODOT" --headless --path . --import || \
			echo "setup: import reported errors; see docs/runbooks/asset-import.md" >&2
	fi
	# A stale .godot/global_script_class_cache.cfg makes headless runs fail to parse scripts that
	# name a newly added class_name; sync it without a full import.
	if [ -d .godot ]; then
		"$VENV/bin/python" tools/refresh_class_cache.py
	fi
else
	echo "setup: Godot not found; install $want and put it on PATH as 'godot' (or set GODOT)" >&2
fi

[ -f .env ] || echo "setup: optional: cp .env.example .env for the GMI key and GRIDFALL_* switches"
echo "setup: done. Activate the tools with: . $VENV/bin/activate"
