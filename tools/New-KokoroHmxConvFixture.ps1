#requires -Version 7.4
<#
.SYNOPSIS
Builds the inputs and exact expected output for the emitted HMX conv runner.

.DESCRIPTION
Signed int8 activations and weights in [-8, 8] from a fixed LCG, packed exactly as
src/emit/Kokoro.HmxConv.ps1 consumes them (see tools/reference/hmx-sim/emitted_conv.c):
activations u8 = x + 128 in time-major croutons with one halo tile of 128 on each side,
weights in (group, tap, input block) order, 256-byte column tables (fp16 0.125 scale,
int32 -128*sum(w) + 128*4096). Expected = sat_u8(floor(acc / 4096) + 128) at the odd bytes
2*IDX(row, c) + 1 of each output crouton. This is an exact integer test reference only.
#>
param(
    [ValidateSet(128, 256)][int] $Channels = 128,
    [ValidateSet(3, 7, 11)][int] $Kernel = 3,
    [ValidateSet(1, 3, 5)][int] $Dilation = 1,
    [ValidateRange(1, 64)][int] $Tiles = 8,
    [uint32] $Seed = 777,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot "../build/hmx-conv-fixture")
)
$ErrorActionPreference = 'Stop'
$cb = $Channels / 32; $groups = $Channels / 64; $frames = 32 * $Tiles; $half = ($Kernel - 1) / 2
$dir = Join-Path $OutputDirectory "c$Channels-k$Kernel-d$Dilation-t$Tiles"
[void][IO.Directory]::CreateDirectory($dir)
# 32-bit LCG matching tools/reference/hmx-sim/emitted_conv.c.
$script:state = [uint32]$Seed
$next = { $script:state = [uint32](([uint64]$script:state * [uint64]1103515245 + [uint64]12345) % [uint64]4294967296); [int](-8 + (($script:state -shr 8) % 17)) }
$idx = { param([int]$i, [int]$j) 64 * [math]::Floor($i / 2) + 2 * $j + ($i % 2) }

$x = [sbyte[]]::new($frames * $Channels)
for ($t = 0; $t -lt $frames; $t++) { for ($c = 0; $c -lt $Channels; $c++) { $x[$t * $Channels + $c] = [sbyte](& $next) } }
$w = [sbyte[]]::new($Kernel * $Channels * $Channels)          # [k][o][i]
for ($n = 0; $n -lt $w.Length; $n++) { $w[$n] = [sbyte](& $next) }

$act = [byte[]]::new(($Tiles + 2) * $cb * 2048); [Array]::Fill($act, [byte]128)
for ($t = 0; $t -lt $frames; $t++) { for ($c = 0; $c -lt $Channels; $c++) {
    $at = (([math]::Floor($t / 32) + 1) * $cb + [math]::Floor($c / 32)) * 2048 + 2 * (& $idx ($t % 32) ($c % 32)) + 1
    $act[$at] = [byte]($x[$t * $Channels + $c] + 128) } }

$wp = [byte[]]::new($groups * $Kernel * $cb * 2048)
for ($g = 0; $g -lt $groups; $g++) { for ($k = 0; $k -lt $Kernel; $k++) { for ($b = 0; $b -lt $cb; $b++) {
    $base = (($g * $Kernel + $k) * $cb + $b) * 2048
    for ($h = 0; $h -lt 2; $h++) { for ($ii = 0; $ii -lt 32; $ii++) { for ($cc = 0; $cc -lt 32; $cc++) {
        $o = 64 * $g + 32 * $h + $cc; $i = 32 * $b + $ii
        $wp[$base + 1024 * $h + 128 * [math]::Floor($ii / 4) + 4 * $cc + ($ii % 4)] = [byte]([int]$w[($k * $Channels + $o) * $Channels + $i] -band 255)
    } } } } } }

$tbl = [byte[]]::new($cb * 256)
for ($o = 0; $o -lt $Channels; $o++) {
    $sw = 0; for ($k = 0; $k -lt $Kernel; $k++) { for ($i = 0; $i -lt $Channels; $i++) { $sw += $w[($k * $Channels + $o) * $Channels + $i] } }
    $ob = [math]::Floor($o / 32); $cc = $o % 32
    [BitConverter]::GetBytes([uint32]0x3000).CopyTo($tbl, $ob * 256 + 4 * $cc)
    [BitConverter]::GetBytes([int](-128 * $sw + 128 * 4096)).CopyTo($tbl, $ob * 256 + 128 + 4 * $cc)
}

# Exact integer reference.
$expected = [byte[]]::new($Tiles * $cb * 2048)
$row = [int[]]::new($Channels)
for ($t = 0; $t -lt $frames; $t++) {
    for ($o = 0; $o -lt $Channels; $o++) {
        $acc = 0
        for ($k = 0; $k -lt $Kernel; $k++) {
            $ts = $t + $Dilation * ($k - $half); if ($ts -lt 0 -or $ts -ge $frames) { continue }
            $xo = $ts * $Channels; $wo = ($k * $Channels + $o) * $Channels
            for ($i = 0; $i -lt $Channels; $i++) { $acc += [int]$x[$xo + $i] * [int]$w[$wo + $i] }
        }
        $q = [math]::Floor($acc / 4096) + 128; if ($q -lt 0) { $q = 0 } elseif ($q -gt 255) { $q = 255 }
        $expected[(([math]::Floor($t / 32)) * $cb + [math]::Floor($o / 32)) * 2048 + 2 * (& $idx ($t % 32) ($o % 32)) + 1] = [byte]$q
    }
}
$files = [ordered]@{ 'activations.bin' = $act; 'weights.bin' = $wp; 'tables.bin' = $tbl; 'expected.bin' = $expected }
foreach ($name in $files.Keys) { [IO.File]::WriteAllBytes((Join-Path $dir $name), $files[$name]) }
[pscustomobject]@{
    Directory = $dir; Channels = $Channels; Kernel = $Kernel; Dilation = $Dilation; Tiles = $Tiles; Seed = $Seed
    ActivationBytes = $act.Length; WeightBytes = $wp.Length; TableBytes = $tbl.Length; OutputBytes = $expected.Length
    ExpectedSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected))
}
