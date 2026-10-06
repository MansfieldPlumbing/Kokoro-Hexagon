#!/bin/bash
# Build one probe with the SDK compiler and run it in the V73 simulator: run-sim.sh <name> [args...]
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
# hexagon-sim links libncurses.so.5/libtinfo.so.5; point those names at the installed .so.6 in a /tmp shim.
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
name="$1"; shift
"$T/bin/hexagon-clang" -mv73 -mhmx -mhvx -O2 "$here/$name.c" -o "$work/$name.elf"
timeout 600 "$T/bin/hexagon-sim" -mv73 --mhmx 1 "$work/$name.elf" -- "$@" 2>&1 | grep -vE '^\s+T[0-9]:|Total:|rev_id|^$' || true
rm -rf "$work"
