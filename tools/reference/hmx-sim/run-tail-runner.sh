#!/bin/bash
# Reference-only simulator OS shim for the generator tail job: run-tail-runner.sh <fixture>
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
fixture="$1"
[[ ! -e "$fixture/simulator-output.bin" ]]
work="$(mktemp -d /tmp/kokoro-tail-runner-XXXXXX)"
shim=/tmp/hexagon-ncshim
mkdir -p "$shim"
ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6 "$shim/libncurses.so.5"
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 "$shim/libtinfo.so.5"
export LD_LIBRARY_PATH="$shim:${LD_LIBRARY_PATH:-}"
"$T/bin/hexagon-clang" -mv73 -mhvx -mhvx-length=128b -O2 -include "$fixture/runner-image.h" "$here/tail_runner.c" -o "$work/runner.elf"
timeout 5400 "$T/bin/hexagon-sim" -mv73 "$work/runner.elf" -- "$fixture" > "$fixture/runner-simulator.log" 2>&1 || true
grep -E 'TailRunner|RunnerOk|exception|CRASH|rror' "$fixture/runner-simulator.log"
case "$work" in /tmp/kokoro-tail-runner-*) rm -r -- "$work" ;; *) exit 5 ;; esac
grep -Eq 'TailRunnerRc=0 Stage=7 Done=1|RunnerOk=1' "$fixture/runner-simulator.log"
