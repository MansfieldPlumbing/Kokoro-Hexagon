#!/bin/bash
# Run PowerShell-emitted user-DMA copy code in the V73 simulator: run-dma-copy.sh <emitted-code.bin>
set -euo pipefail
T=/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools
here="$(cd "$(dirname "$0")" && pwd)"
bin="$1"
work="$(mktemp -d /tmp/kokoro-dma-copy-XXXXXX)"
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
"$T/bin/hexagon-clang" -mv73 -O2 -include "$work/emitted_code.h" "$here/dma_copy.c" -o "$work/dma_copy.elf"
timeout 900 "$T/bin/hexagon-sim" -mv73 "$work/dma_copy.elf" 2>&1 | grep -E 'dma-copy|FAIL|rror' || true
case "$work" in /tmp/kokoro-dma-copy-*) rm -r -- "$work" ;; *) exit 5 ;; esac
