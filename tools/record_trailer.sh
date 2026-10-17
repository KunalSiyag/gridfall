#!/usr/bin/env bash
# Records the ~30 s GridFall trailer (1080p30) with Godot Movie Maker and encodes an X-ready MP4.
# Usage: tools/record_trailer.sh [out.mp4]   (needs godot and ffmpeg on PATH, GMI key for live mayors)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-trailer/gridfall_trailer.mp4}"
TMP="$(mktemp -d)"
mkdir -p "$(dirname "$OUT")"
# Movie Maker records at the project viewport size, so swap in a 1080p viewport for this run only.
cp tools/record/override_1080p.cfg override.cfg
trap 'rm -f override.cfg; rm -rf "$TMP"' EXIT
if [ ! -f "$HOME/.local/share/godot/app_userdata/GridFall — GMI Cloud Multi-Model Crisis Sim/gridfall_cinematic.json" ] || [ "${REPREP:-0}" = "1" ]; then
	GRIDFALL_CINEMATIC=prep godot --headless --path .
fi
GRIDFALL_CINEMATIC=record godot --path . --write-movie "$TMP/take.avi" --fixed-fps 30
ffmpeg -y -loglevel error -ss 0.6 -i "$TMP/take.avi" -t 30.9 \
	-vf "fade=t=out:st=30.2:d=0.7,format=yuv420p" \
	-af "afade=t=in:d=0.5,afade=t=out:st=29.6:d=1.3,loudnorm=I=-16:TP=-1.5" \
	-c:v libx264 -preset slow -crf 20 -maxrate 16M -bufsize 32M -profile:v high -level 4.2 -r 30 -g 60 \
	-c:a aac -b:a 160k -ar 48000 -movflags +faststart "$OUT"
echo "Trailer written to $OUT"
