#!/bin/bash
# Run PowerShell-emitted looped two-group HMX conv code in the V73 simulator: run-emitted-loop.sh <emitted-code.bin> <CI> <CO> <K> <D> <WP> <LA> <LB>
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
bin="$1"; ci="$2"; co="$3"; kk="$4"; dd="$5"; wp="$6"; la="$7"; lb="$8"
work="$(mktemp -d)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
{
  echo '__attribute__((section(".text"), aligned(64))) static const unsigned char EMITTED_CODE[] = {'
  od -An -v -tx1 "$bin" | sed 's/\([0-9a-f][0-9a-f]\)/0x\1,/g'
  echo '};'
} > "$work/emitted_code.h"
"$T/bin/hexagon-clang" -mv73 -mhmx -mhvx -O2 -DCI="$ci" -DCO="$co" -DKK="$kk" -DDD="$dd" -DWP="$wp" -DLA="$la" -DLB="$lb" -include "$work/emitted_code.h" "$here/emitted_conv_loop.c" -o "$work/emitted_conv_loop.elf"
timeout "${SIM_TIMEOUT:-900}" "$T/bin/hexagon-sim" -mv73 --mhmx 1 "$work/emitted_conv_loop.elf" 2>&1 | grep -E 'emitted|FAIL|PASS|rror' || true
rm -rf "$work"
