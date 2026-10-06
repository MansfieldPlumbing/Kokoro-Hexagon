#!/bin/bash
# Reference only. Args: statistics.bin coefficients.bin affine.bin fixture tiles frames
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
stats="$1"; coeff="$2"; affine="$3"; fixture="$4"; tiles="$5"; frames="$6"; channels="${7:-128}"
[[ "$tiles" =~ ^[0-9]+$ && "$frames" =~ ^[0-9]+$ ]]
(( tiles>=1 && tiles<=245 && frames>=2 && frames<=tiles*32 && frames>(tiles-1)*32 ))
[[ "$channels" == 128 || "$channels" == 256 ]]; ((tiles*channels*64<=2031616))
[[ ! -e "$fixture/simulator-affine.bin" && ! -e "$fixture/simulator-coefficients.bin" ]]
work="$(mktemp -d /tmp/kokoro-adain-integer-XXXXXX)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
emit_array() {
 echo "__attribute__((section(\".text\"),aligned(64))) static const unsigned char $1[] = {"
 od -An -v -tx1 "$2" | sed 's/\([0-9a-f][0-9a-f]\)/0x\1,/g'
 echo '};'
}
{
 emit_array STATISTICS_CODE "$stats"
 emit_array COEFFICIENTS_CODE "$coeff"
 emit_array AFFINE_CODE "$affine"
} > "$work/emitted_code.h"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 -DNT="$tiles" -DNF="$frames" -DNC="$channels" -include "$work/emitted_code.h" "$here/adain_integer.c" -o "$work/adain.elf"
timeout 900 "$T/bin/hexagon-sim" -mv73 "$work/adain.elf" -- "$fixture/activations.bin" "$fixture/parameters.bin" "$fixture/moments.bin" "$fixture/simulator-coefficients.bin" "$fixture/simulator-affine.bin" > "$fixture/simulator.log" 2>&1
grep -E 'integer-adain|FAIL|rror' "$fixture/simulator.log"
case "$work" in /tmp/kokoro-adain-integer-*) rm -r -- "$work" ;; *) exit 5 ;; esac
