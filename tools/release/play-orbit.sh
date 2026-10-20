#!/bin/sh
# Start GridFall in the orbit city-builder view instead of on foot.
cd "$(dirname "$0")" || exit 1
GRIDFALL_VIEW=orbit exec ./gridfall.x86_64 "$@"
