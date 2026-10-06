#!/bin/bash
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)";code="$1";fixture="$2";tiles="$3";channels="${4:-128}"
[[ "$tiles" =~ ^[0-9]+$ ]];((tiles>=1&&tiles<=1024));[[ ! -e "$fixture/simulator-output.bin" ]]
[[ "$channels" == 128 || "$channels" == 256 ]]
work="$(mktemp -d /tmp/kokoro-branch-average-XXXXXX)";shim=/tmp/hexagon-ncshim
mkdir -p "$shim";ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5";ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
{ echo '__attribute__((section(".text"),aligned(64))) static const unsigned char CODE[] = {';od -An -v -tx1 "$code"|sed 's/\([0-9a-f][0-9a-f]\)/0x\1,/g';echo '};';} > "$work/code.h"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 -DNT="$tiles" -DNC="$channels" -include "$work/code.h" "$here/branch_average_integer.c" -o "$work/check.elf"
timeout 600 "$T/bin/hexagon-sim" -mv73 "$work/check.elf" -- "$fixture" > "$fixture/simulator.log" 2>&1
grep -E 'BranchAverage|FAIL|rror' "$fixture/simulator.log"
