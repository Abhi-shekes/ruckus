#!/usr/bin/env bash
#
# Launch Ruckus with the compatibility shims it needs on older Ubuntu.
#
# Two libraries are missing or too new on Ubuntu 20.04:
#   libFLAC.so.14  — checked in, rebuilt at glibc 2.29 (see linux/prebuilt/)
#   libsqlite3.so  — the unversioned name, symlinked below from the system copy
#
# Both are put on LD_LIBRARY_PATH, which the loader consults before any
# RUNPATH, so nothing in the pub cache or in /usr/lib is modified.
# On Ubuntu 22.04+ none of this is needed and the script is a no-op wrapper.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/linux/prebuilt/glibc231"
BIN="$HERE/build/linux/x64/debug/bundle/ruckus"

# sqflite_common_ffi opens the unversioned "libsqlite3.so", which only exists
# when libsqlite3-dev is installed. Point at whatever the system already has.
if [[ ! -e "$SHIM/libsqlite3.so" ]]; then
  for candidate in \
    /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 \
    /usr/lib/libsqlite3.so.0 \
    /lib/x86_64-linux-gnu/libsqlite3.so.0
  do
    if [[ -e "$candidate" ]]; then
      ln -sf "$candidate" "$SHIM/libsqlite3.so"
      break
    fi
  done
fi

if [[ ! -x "$BIN" ]]; then
  echo "Ruckus is not built yet. Run:" >&2
  echo "    flutter build linux --debug" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$SHIM${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$BIN" "$@"
