#!/bin/bash
# Reference-only simulator OS shim, same PowerShell-emitted ELF bytes as device.
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
emission="$1"; fixture="$2"
mode="${3:-connected}"
if [[ "$mode" == admission ]]; then
 defines=(-DADMISSION_ONLY=1); logfile="$fixture/runner-admission.log"
else
 [[ "$mode" == connected && ! -e "$fixture/simulator-workspace.bin" ]]
 defines=(); logfile="$fixture/runner-simulator.log"
fi
work="$(mktemp -d /tmp/kokoro-resblock-runner-XXXXXX)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 "${defines[@]}" -include "$fixture/runner-image.h" "$here/resblock_runner.c" -o "$work/runner.elf"
cp "$work/runner.elf" "$fixture/reference-$mode.elf"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 "${defines[@]}" -S -include "$fixture/runner-image.h" "$here/resblock_runner.c" -o "$fixture/reference-$mode.s"
timeout 5400 "$T/bin/hexagon-sim" -mv73 "$work/runner.elf" -- "$fixture" > "$logfile" 2>&1
grep -E 'ConnectedRunner|AdmissionChecks|FAIL|rror' "$logfile"
echo "ReferenceExecutable=$work/runner.elf"
