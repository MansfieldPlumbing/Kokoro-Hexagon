#!/bin/bash
# Reference-only connected test, blocking DDR/VTCM copies, no throughput claim.
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
fixture="${9}"; tiles="${10}"; frames="${11}"
kernel="${12:-3}"; [[ "$kernel" == 3 || "$kernel" == 7 || "$kernel" == 11 ]]
[[ "$tiles" =~ ^[0-9]+$ && "$frames" =~ ^[0-9]+$ ]]
(( tiles>=1 && tiles<=1024 && frames>=2 && frames<=32768 && frames<=tiles*32 && frames>(tiles-1)*32 ))
[[ ! -e "$fixture/stage0/connected-adain.bin" ]]
work="$(mktemp -d /tmp/kokoro-resblock-integer-XXXXXX)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
names=(STATISTICS_CODE COEFFICIENTS_CODE AFFINE_CODE SNAKE_CODE RESIDUAL_CODE CONV_D1_CODE CONV_D3_CODE CONV_D5_CODE)
codes=("$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8")
{
 for i in {0..7}; do
  echo "__attribute__((section(\".text\"),aligned(64))) static const unsigned char ${names[$i]}[] = {"
  od -An -v -tx1 "${codes[$i]}" | sed 's/\([0-9a-f][0-9a-f]\)/0x\1,/g'
  echo '};'
 done
} > "$work/emitted_code.h"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 -DNT="$tiles" -DNF="$frames" -DWBYTES="$((kernel*16384))" -include "$work/emitted_code.h" "$here/resblock_integer.c" -o "$work/resblock.elf"
timeout 1800 "$T/bin/hexagon-sim" -mv73 "$work/resblock.elf" -- "$fixture" > "$fixture/simulator.log" 2>&1
grep -E 'connected-resblock|FAIL|rror' "$fixture/simulator.log"
case "$work" in /tmp/kokoro-resblock-integer-*) rm -r -- "$work" ;; *) exit 5 ;; esac
