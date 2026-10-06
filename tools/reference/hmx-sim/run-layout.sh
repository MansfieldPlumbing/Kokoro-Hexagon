#!/bin/bash
# Print SDK struct layouts with the SDK compiler in the V73 simulator: run-layout.sh <probe>
set -euo pipefail
S=/home/scott/hexagon/Hexagon_SDK/6.4.0.2
T=$S/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
"$T/bin/hexagon-clang" -mv73 -O1 -I "$S/incs" -I "$S/incs/stddef" "$here/$1.c" -o "$work/$1.elf"
timeout 300 "$T/bin/hexagon-sim" -mv73 "$work/$1.elf" 2>&1 | grep -vE '^\s+T[0-9]:|Total:|rev_id|^$|Done' || true
rm -rf "$work"
