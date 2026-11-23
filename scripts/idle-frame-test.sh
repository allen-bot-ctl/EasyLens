#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# 0.1.14: hidden lens must draw 0 frames; reshow must resume drawing.
if [ "$(uname)" = "Linux" ]; then
  exec xvfb-run -a --server-args="-screen 0 1280x800x24" \
    npx electron . --idle-frame-test --no-sandbox --disable-dev-shm-usage
fi
exec npx electron . --idle-frame-test
