#requires -Version 7.4
# Author a complete FP16 MatMul weight payload from logical coordinates into a prepared
# QNN context, using the proven V73 K-pair fold: half = (k>>1)*(N*2) + n*2 + (k&1).
#
# The 2026-08 version of this wrote all zeros: its loops were `for ($k = 0; $k -lt $K; ...)`
# against `param([int]$K = 32)`, and PowerShell variable names are case-insensitive, so the
# condition was `0 -lt 0` and neither loop body ran. Loop variables here cannot shadow the
# bounds.
[CmdletBinding()]
param(
    [string] $Template   = 'C:\Dev\Kokoro-QNN-old\qnn-pings\PING_32.QNN',
    [string] $OutDir     = 'C:\Dev\Build\Kokoro-QNN\author\identity32',
    [int]    $Krows      = 32,
    [int]    $Ncols      = 32,
    [long]   $WeightBase = 0x9000
)
$ErrorActionPreference = 'Stop'
[void](New-Item -ItemType Directory -Force $OutDir)

[byte[]]$bytes = [IO.File]::ReadAllBytes($Template)
'template {0} ({1:N0} bytes)' -f (Split-Path $Template -Leaf), $bytes.Length

[ushort[]]$packed = [ushort[]]::new($Krows * $Ncols)
[int]$written = 0
for ([int]$kk = 0; $kk -lt $Krows; $kk++) {
    for ([int]$nn = 0; $nn -lt $Ncols; $nn++) {
        [float]$val = if ($kk -eq $nn) { 1.0 } else { 0.0 }
        [ushort]$half = [BitConverter]::ToUInt16([BitConverter]::GetBytes([Half]$val), 0)
        [int]$phys = ($kk -shr 1) * ($Ncols * 2) + ($nn * 2) + ($kk -band 1)
        $packed[$phys] = $half
        $written++
    }
}
if ($written -ne $Krows * $Ncols) { throw "loop wrote $written of $($Krows * $Ncols) elements" }

[int]$nonZero = 0
foreach ($h in $packed) { if ($h -ne 0) { $nonZero++ } }
if ($nonZero -ne $Krows) { throw "identity should have $Krows non-zero halfwords, has $nonZero" }

for ([int]$i = 0; $i -lt $packed.Length; $i++) {
    [byte[]]$hb = [BitConverter]::GetBytes($packed[$i])
    $bytes[$WeightBase + $i * 2] = $hb[0]
    $bytes[$WeightBase + $i * 2 + 1] = $hb[1]
}

$ctx = Join-Path $OutDir 'identity32_ctx_qnn.bin'
[IO.File]::WriteAllBytes($ctx, $bytes)

# X = all ones, so Y[n] = sum_k W[k,n] = 1 for an identity.
[float[]]$ones = [float[]]::new($Ncols)
for ([int]$i = 0; $i -lt $Ncols; $i++) { $ones[$i] = 1.0 }
[byte[]]$ob = [byte[]]::new($Ncols * 4)
[Buffer]::BlockCopy($ones, 0, $ob, 0, $ob.Length)
[IO.File]::WriteAllBytes((Join-Path $OutDir 'in_PING_32_X.f32'), $ob)
[IO.File]::WriteAllBytes((Join-Path $OutDir 'oracle_PING_32_Y.f32'), $ob)

'wrote {0} logical elements, {1} non-zero halfwords' -f $written, $nonZero
'context {0}  sha {1}' -f (Split-Path $ctx -Leaf), (Get-FileHash $ctx).Hash.Substring(0, 16)
