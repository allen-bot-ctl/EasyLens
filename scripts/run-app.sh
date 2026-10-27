#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
"$repo_dir/scripts/build-app.sh"
exec "$repo_dir/build/EasyLens.app/Contents/MacOS/EasyLens" "$@"
