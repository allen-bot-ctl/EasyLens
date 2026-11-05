#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Runs the real Electron process under a virtual X server so CI/headless Linux
# can verify startup, tray creation, transparent windows and the demo card.
if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run is required for the smoke test" >&2
  exit 2
fi

exec xvfb-run -a --server-args="-screen 0 1280x800x24" \
  npx electron . --smoke-test --no-sandbox --disable-dev-shm-usage
