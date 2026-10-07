#!/bin/bash
# Fused AdaIN+Snake against frozen affine -> Snake in the V73 simulator:
# run-adain-snake-fused.sh <affine.bin> <snake.bin> <fused.bin> <generator60x fixture dir>
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d /tmp/kokoro-adain-snake-fused-XXXXXX)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
emit() {
  echo "__attribute__((section(\".text\"), aligned(64))) static const unsigned char $1[] = {"
  od -An -v -tx1 "$2" | sed 's/\([0-9a-f][0-9a-f]\)/0x\1,/g'
  echo '};'
}
{ emit AFFINE_CODE "$1"; emit SNAKE_CODE "$2"; emit FUSED_CODE "$3"; } > "$work/emitted_code.h"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 -include "$work/emitted_code.h" "$here/adain_snake_fused.c" -o "$work/fused.elf"
timeout 3600 "$T/bin/hexagon-sim" -mv73 "$work/fused.elf" -- "$4" 2>&1 | grep -E 'adain-snake-fused|FAIL|rror' || true
case "$work" in /tmp/kokoro-adain-snake-fused-*) rm -r -- "$work" ;; *) exit 5 ;; esac
