#!/bin/bash
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
bin="$1"; fixture="$2"; tiles="$3"; channels="${4:-128}"
[[ "$tiles" =~ ^[0-9]+$ ]] && (( tiles>=1 && tiles<=1024 ))
[[ "$channels" == 128 || "$channels" == 256 ]]
[[ ! -e "$fixture/simulator-output.bin" ]]
work="$(mktemp -d /tmp/kokoro-snake-integer-XXXXXX)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
{
 echo '__attribute__((section(".text"),aligned(64))) static const unsigned char EMITTED_CODE[] = {'
 od -An -v -tx1 "$bin" | sed 's/\([0-9a-f][0-9a-f]\)/0x\1,/g'
 echo '};'
} > "$work/emitted_code.h"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 -DNT="$tiles" -DNC="$channels" -include "$work/emitted_code.h" "$here/snake_integer.c" -o "$work/snake.elf"
timeout 900 "$T/bin/hexagon-sim" -mv73 "$work/snake.elf" -- "$fixture/input.bin" "$fixture/parameters.bin" "$fixture/simulator-output.bin" > "$fixture/simulator.log" 2>&1
grep -E 'integer-snake|FAIL|rror' "$fixture/simulator.log"
case "$work" in /tmp/kokoro-snake-integer-*) rm -r -- "$work" ;; *) exit 5 ;; esac
