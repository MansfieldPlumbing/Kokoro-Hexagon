#requires -Version 7.4
<# .SYNOPSIS
Experiment driver behind the 2026-10-10 decoder AdaIN receipts (docs/adain-control-stream-design.md): runs the decoder
job's -Moments modes on the phone for the hello-world decoder fixture (65 frames) and two chunks of it.
.DESCRIPTION
Check Corrected: per chunk, Corrected with zero deltas against ordinary chunks (Export), and Corrected with oracle
deltas (one pass minus SuppliedExport local coefficients) against SuppliedExport; then stitched SNR against the one
pass (docs/results/decoder-coefficient-correction-sm8550-20261010.md, decoder-supplied-moments-...).
Check Direct: the one pass's exported coefficients loaded with Direct, whole and per chunk, against the one pass and
Supplied (docs/results/decoder-direct-coefficients-sm8550-20261010.md).
Phone access through Invoke-KokoroDeviceJob; emissions through Invoke-KokoroEmission; inputs under build/adain-km.
To be absorbed into the entrypoint's `Speak` / `AdaInControl` commands when they exist.
#>
param([ValidateSet('Corrected', 'Direct')][string]$Check = 'Corrected', [int[]]$ChunkBounds = @(0, 41, 24, 65), [int]$RunCount = 3)
# Dot-sourcing the entrypoint binds its parameters (Runs, Case, Path, ...) in this scope: keep names distinct.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repo 'Invoke-KokoroDevelopment.ps1')
Import-CaptureKernels; Import-Evaluator
$DirectOnly = $Check -eq 'Direct'
$fx = Join-Path $repo 'build\decoder16-fixture-20261009m4d'
$units = [double[]]@((Get-Content (Join-Path $fx 'fixture.json') -Raw | ConvertFrom-Json).DecoderScales)
$F = 65; $Tiles = 3; $curve = 640L
$act = [IO.File]::ReadAllBytes((Join-Path $fx 'activations.bin'))
$work = Join-Path $repo 'build\adain-km'; $null = New-Item -ItemType Directory -Force $work
$modes = 'Export', 'Supplied', 'SuppliedExport', 'Corrected', 'Direct'
$emit = @{}; foreach ($m in $modes) {
    $e = Invoke-KokoroEmission -Kernel 'KokoroDecoder16Run' -Parameters @{ DecoderFrames = $F; DecoderRuntimeFrames = $true; DecoderMoments = $m }
    $emit[$m] = $e.Directory; $emit["$m.layout"] = Get-Content (Join-Path $e.Directory 'runner-layout.json') -Raw | ConvertFrom-Json
    [Console]::WriteLine(('skel {0,-15} {1}' -f $m, $e.LibrarySHA256)) }
$lay = $emit['Corrected.layout']; $kmBytes = [long](($lay.MomentSites | Measure-Object KmBytes -Sum).Sum); $mBytes = [long](($lay.MomentSites | Measure-Object Bytes -Sum).Sum)

function New-ChunkActivations([int]$a, [int]$n) {
    $b = [byte[]]::new(99584); for ($i = 1; $i -lt $Tiles * 32768; $i += 2) { $b[$i] = 0x80 }
    for ($t = 0; $t -lt $n; $t++) { $s = $a + $t
        for ($c = 0; $c -lt 512; $c++) {
            # Packing API contract: halfword index of (t, c) in 512-wide croutons.
            $hs = (($s -shr 5) * 16 + ($c -shr 5)) * 1024 + 64 * (($s -band 31) -shr 1) + 2 * ($c -band 31) + ($s -band 1)
            $hd = (($t -shr 5) * 16 + ($c -shr 5)) * 1024 + 64 * (($t -band 31) -shr 1) + 2 * ($c -band 31) + ($t -band 1)
            $b[2 * $hd] = $act[2 * $hs]; $b[2 * $hd + 1] = $act[2 * $hs + 1] } }
    foreach ($k in 0, 1) { [Array]::Copy($act, $Tiles * 32768L + $k * $curve + 8L * $a, $b, $Tiles * 32768L + $k * $curve, 8L * $n) }
    , $b
}
function New-Input([string]$name, [string]$mode, [byte[]]$activations, [int]$frames, [byte[]]$records, [int[]]$counts, [byte[]]$deltas) {
    $dir = Join-Path $work $name; $null = New-Item -ItemType Directory -Force $dir
    foreach ($f in 'weights.bin', 'tables.bin') { $p = Join-Path $dir $f; if (-not (Test-Path $p)) { $null = New-Item -ItemType HardLink -Path $p -Target (Join-Path $fx $f) } }
    $l = $emit["$mode.layout"]
    $b = [byte[]]::new($l.InputBytes); [Array]::Copy($activations, $b, $activations.Length)
    [BitConverter]::GetBytes([int]$frames).CopyTo($b, $l.FramesOffset)
    if ($records) { [Array]::Copy($records, 0, $b, $l.MomentsInputOffset, $records.Length); for ($i = 0; $i -lt $counts.Count; $i++) { [BitConverter]::GetBytes($counts[$i]).CopyTo($b, $l.MomentCountsInputOffset + 4 * $i) } }
    if ($deltas) { [Array]::Copy($deltas, 0, $b, $l.KmDeltasInputOffset, $deltas.Length) }
    [IO.File]::WriteAllBytes((Join-Path $dir 'activations.bin'), $b); $dir
}
function Invoke-Decoder([string]$mode, [string]$dir) {
    $r = Invoke-KokoroDeviceJob -EmissionDirectory $emit[$mode] -InputDirectory $dir -Runs $RunCount
    $l = $emit["$mode.layout"]
    $out = [byte[]]::new(163840); [Array]::Copy($r.Output, 256, $out, 0, 163840)
    $rec = $null; $km = $null
    if ($mode -in 'Export', 'SuppliedExport') { $rec = [byte[]]::new($mBytes); [Array]::Copy($r.Output, $l.MomentsOutputOffset, $rec, 0, $mBytes); $km = [byte[]]::new($kmBytes); [Array]::Copy($r.Output, $l.KmOutputOffset, $km, 0, $kmBytes) }
    [pscustomobject]@{ Output = $out; Records = $rec; Km = $km; MedianMs = $r.MedianMs }
}
# a - b per int32, wrapping (vadd-w wraps).
function Get-Delta([byte[]]$a, [byte[]]$b) { $d = [byte[]]::new($a.Length); for ($i = 0; $i -lt $a.Length; $i += 4) { $v = ([long][BitConverter]::ToInt32($a, $i) - [long][BitConverter]::ToInt32($b, $i)) -band 0xffffffffL; [BitConverter]::GetBytes([uint32]$v).CopyTo($d, $i) }; , $d }
function Get-Snr([float[]]$ref, [float[]]$x) { $s = 0.0; $e = 0.0; for ($i = 0; $i -lt $ref.Length; $i++) { $s += [double]$ref[$i] * $ref[$i]; $d = [double]$ref[$i] - $x[$i]; $e += $d * $d }; if ($e -eq 0) { [double]::PositiveInfinity } else { 10 * [math]::Log10($s / $e) } }
# Any parity difference makes the script exit 1 (a gate, not only a report).
$script:ParityFailures = 0
function Test-Same([byte[]]$x, [byte[]]$y) { if ([Linq.Enumerable]::SequenceEqual($x, $y)) { 'bit-exact' } else { $script:ParityFailures++; $n = 0; for ($i = 0; $i -lt $x.Length; $i += 2) { if ($x[$i] -ne $y[$i] -or $x[$i + 1] -ne $y[$i + 1]) { $n++ } }; "DIFFERS in $n halfwords" } }

$whole = Invoke-Decoder 'Export' (New-Input 'whole-export' 'Export' (New-ChunkActivations 0 $F) $F)
$counts = @($lay.MomentSites | ForEach-Object { if ($_.Count -eq 'F2') { 2 * $F } else { $F } })
$wf = ConvertFrom-KokoroCroutons16 -Bytes $whole.Output -Frames (2 * $F) -Units $units
'whole export: {0:N3} ms' -f $whole.MedianMs
$a0, $b0, $a1, $b1 = $ChunkBounds; $mid = $a1 + $b0
if ($DirectOnly) {
    # Direct: the one pass's exported coefficients loaded as-is; no moments, no coefficient derivation.
    $wd = Invoke-Decoder 'Direct' (New-Input 'whole-direct' 'Direct' (New-ChunkActivations 0 $F) $F $null $null $whole.Km)
    'whole direct vs one pass: {0}; {1:N3} ms (one pass {2:N3} ms)' -f (Test-Same $wd.Output $whole.Output), $wd.MedianMs, $whole.MedianMs
    $parts = foreach ($ab in @(@($a0, $b0), @($a1, $b1))) {
        $a = $ab[0]; $n = $ab[1] - $a; $tag = "$a-$($ab[1])"; $acts = New-ChunkActivations $a $n
        $sup = Invoke-Decoder 'Supplied' (New-Input "sup-$tag" 'Supplied' $acts $n $whole.Records $counts)
        $dir = Invoke-Decoder 'Direct' (New-Input "direct-$tag" 'Direct' $acts $n $null $null $whole.Km)
        [Console]::WriteLine(('chunk [{0}): direct vs supplied {1}; ms supplied {2:N3} direct {3:N3}' -f $tag, (Test-Same $dir.Output $sup.Output), $sup.MedianMs, $dir.MedianMs))
        [pscustomobject]@{ A = $a; N = $n; V = (ConvertFrom-KokoroCroutons16 -Bytes $dir.Output -Frames (2 * $n) -Units $units) } }
    $st = [float[]]::new(512 * 2 * $F)
    for ($c = 0; $c -lt 512; $c++) { for ($t = 0; $t -lt 2 * $F; $t++) { $p = if ($t -lt $mid) { $parts[0] } else { $parts[1] }; $st[$c * 2 * $F + $t] = $p.V[$c * 2 * $p.N + $t - 2 * $p.A] } }
    'Direct stitched: {0:N2} dB vs one pass on the DSP' -f (Get-Snr $wf $st)
    if ($script:ParityFailures) { Write-Error "$($script:ParityFailures) parity check(s) failed"; exit 1 }
    exit 0
}
$stitched = @{}
foreach ($ab in @(@($a0, $b0), @($a1, $b1))) {
    $a = $ab[0]; $n = $ab[1] - $a; $tag = "$a-$($ab[1])"; $acts = New-ChunkActivations $a $n
    $own = Invoke-Decoder 'Export' (New-Input "own-$tag" 'Export' $acts $n)
    $zero = Invoke-Decoder 'Corrected' (New-Input "zero-$tag" 'Corrected' $acts $n $null $null ([byte[]]::new($kmBytes)))
    $sup = Invoke-Decoder 'SuppliedExport' (New-Input "supexp-$tag" 'SuppliedExport' $acts $n $whole.Records $counts)
    $delta = Get-Delta $whole.Km $sup.Km
    $orc = Invoke-Decoder 'Corrected' (New-Input "oracle-$tag" 'Corrected' $acts $n $null $null $delta)
    'chunk [{0}): zero delta vs own {1}; oracle delta vs supplied {2}; ms own {3:N3} corrected {4:N3} supplied {5:N3}' -f $tag, (Test-Same $zero.Output $own.Output), (Test-Same $orc.Output $sup.Output), $own.MedianMs, $orc.MedianMs, $sup.MedianMs
    $stitched[$a] = [pscustomobject]@{ A = $a; N = $n; Own = (ConvertFrom-KokoroCroutons16 -Bytes $own.Output -Frames (2 * $n) -Units $units); Oracle = (ConvertFrom-KokoroCroutons16 -Bytes $orc.Output -Frames (2 * $n) -Units $units) }
}
foreach ($kind in 'Own', 'Oracle') {
    $st = [float[]]::new(512 * 2 * $F)
    for ($c = 0; $c -lt 512; $c++) { for ($t = 0; $t -lt 2 * $F; $t++) { $p = if ($t -lt $mid) { $stitched[$a0] } else { $stitched[$a1] }; $st[$c * 2 * $F + $t] = $p.$kind[$c * 2 * $p.N + $t - 2 * $p.A] } }
    '{0,-6} stitched: {1:N2} dB vs one pass on the DSP' -f $kind, (Get-Snr $wf $st)
}
if ($script:ParityFailures) { Write-Error "$($script:ParityFailures) parity check(s) failed"; exit 1 }
