#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
exec sh "$script_dir/run_local_lens_probe.sh" --whole-display "$@"
