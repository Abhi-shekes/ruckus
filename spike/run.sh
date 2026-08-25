#!/usr/bin/env bash
# Launch the spike with the glibc-compatible libFLAC ahead of the plugin's own.
# Needed only on Ubuntu 20.04; harmless elsewhere.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="$HERE/linux/prebuilt/glibc231${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/build/linux/x64/debug/bundle/soundboard_spike" "$@"
