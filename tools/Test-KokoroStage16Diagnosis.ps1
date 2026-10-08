#requires -Version 7.4
<# .SYNOPSIS
Localizes errors in a 16-bit generator 60x stage run from its captured workspace.
.DESCRIPTION
The Generator60x16 harness capture holds branch 0 and branch 1 results, the final tensor and the K/M/S
records of all 18 stages (Kokoro.Generator60x16Run.ps1). This reports:
  - SNR of branch 0, branch 1 and the final tensor against the stock resblocks.3/.4 outputs and their mean;
  - for branch 0 stage 0 (input R0 from the fixture, so exact): K/M/S against the integer formula of
    Kokoro.AdaInTurnsCoefficients.ps1 applied to R0's moments;
  - for every R-input stage (even): K against the stock-statistics estimate Ka / sqrt(var_int + eps).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Workspace,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [Parameter(Mandatory)][string[]] $CaptureDirectory,
    # A run emitted with -Stage16StopAfter n: score its final slot (stage n's C or R) against stock.
    [ValidateRange(-1,17)][int] $DumpStage = -1
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureMath.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1') -Force
$fx = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$frames = [int]$fx.Frames; $tiles = [int]$fx.Tiles; $sR = [double[]]@($fx.OutputScales); $N = $frames
$tensor = $tiles * 8192; $stride = [int]([math]::Ceiling($tensor / 128) * 128)
$ws = [IO.File]::ReadAllBytes($Workspace)
if ($ws.Length -ne 2 * $stride + $tensor + 18 * 1536) { throw "Workspace capture is $($ws.Length) bytes; expected $(2 * $stride + $tensor + 18 * 1536)." }
$caps = foreach ($d in $CaptureDirectory) { Read-KokoroCapture -Directory $d }
$snr = { param([byte[]]$croutons, [float[]]$ref)
    $sig = [double[]]::new(128); $noi = [double[]]::new(128)
    $mx = (Get-Croutons16ErrorKernel).Invoke($croutons, $ref, $frames, $sR, $sig, $noi)
    $s = 0.0; $n = 0.0; foreach ($v in $sig) { $s += $v }; foreach ($v in $noi) { $n += $v }
    [pscustomobject]@{ SnrDb = [math]::Round(10 * [math]::Log10($s / [math]::Max($n, 1e-300)), 2); MaxAbsError = [math]::Round($mx, 4) }
}
$slice = { param([long]$at, [int]$length) $b = [byte[]]::new($length); [Buffer]::BlockCopy($ws, $at, $b, 0, $length); , $b }
if ($DumpStage -ge 0) {
    $b = [math]::Floor($DumpStage / 6); $s = $DumpStage % 6
    $name = if ($s % 2 -eq 0) { "stage$s.conv" } elseif ($s -lt 5) { "stage$($s + 1).input" } else { 'output' }
    $all = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'stage-output-scales.bin')); $scales = [double[]]::new(128); [Buffer]::BlockCopy($all, 8 * 128 * $DumpStage, $scales, 0, 1024)
    $sig = [double[]]::new(128); $noi = [double[]]::new(128)
    $mx = (Get-Croutons16ErrorKernel).Invoke((& $slice (2 * $stride) $tensor), (Read-KokoroCaptureTensor -Capture $caps[$b] -Name $name), $frames, $scales, $sig, $noi)
    $sn = 0.0; $nn = 0.0; foreach ($v in $sig) { $sn += $v }; foreach ($v in $noi) { $nn += $v }
    $worst = (0..127 | ForEach-Object { [pscustomobject]@{ C = $_; Db = 10 * [math]::Log10($sig[$_] / [math]::Max($noi[$_], 1e-300)) } } | Sort-Object Db | Select-Object -First 3)
    return [pscustomobject]@{ Stage = $DumpStage; Reference = "resblocks.$(3 + $b) $name"; SnrDb = [math]::Round(10 * [math]::Log10($sn / [math]::Max($nn, 1e-300)), 2); MaxAbsError = $mx; WorstChannels = ($worst | ForEach-Object { "c$($_.C)=$([math]::Round($_.Db, 1))dB" }) -join ' ' }
}
$o3 = Read-KokoroCaptureTensor -Capture $caps[0] -Name 'output'; $o4 = Read-KokoroCaptureTensor -Capture $caps[1] -Name 'output'; $o5 = Read-KokoroCaptureTensor -Capture $caps[2] -Name 'output'
$mean = [float[]]::new($o3.Length); (Get-Mean3Kernel).Invoke($o3, $o4, $o5, $mean)
$result = [ordered]@{
    Branch0 = & $snr (& $slice 0 $tensor) $o3
    Branch1 = & $snr (& $slice $stride $tensor) $o4
    Final = & $snr (& $slice (2 * $stride) $tensor) $mean
}

# K/M/S records: per stage 1536 bytes, K[128], M[128], S[128] int32.
$coef = 2 * $stride + $tensor
$kms = { param([int]$rec, [int]$which, [int]$c) [BitConverter]::ToInt32($ws, $coef + $rec * 1536 + 512 * $which + 4 * $c) }
$tables = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'tables.bin'))
$param = { param([int]$rec, [int]$c) [pscustomobject]@{ Ka = [BitConverter]::ToInt64($tables, $rec * 16384 + 32 * $c); Mb = [BitConverter]::ToInt32($tables, $rec * 16384 + 32 * $c + 8); S = [BitConverter]::ToInt32($tables, $rec * 16384 + 32 * $c + 12); EpsD = [BitConverter]::ToUInt64($tables, $rec * 16384 + 32 * $c + 16) } }

# Branch 0 stage 0, exact: moments of the fixture's R0.
$r0 = [float[]]::new(128 * $frames); (Get-DecodeCroutons16Kernel).Invoke([IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'activations.bin')), $frames, 128, $r0)
$am = [double[]]::new(128); $s1 = [double[]]::new(128); $s2 = [double[]]::new(128); (Get-ChannelStatsKernel).Invoke($r0, 128, $am, $s1, $s2)
$kBad = 0; $mBad = 0; $sBad = 0; $kWorst = 0.0
for ($c = 0; $c -lt 128; $c++) {
    $p = & $param 0 $c
    $D = [double]$N * $s2[$c] - $s1[$c] * $s1[$c] + [double]$p.EpsD; $root = [math]::Floor([math]::Sqrt($D))
    $kExp = [math]::Min([math]::Round([math]::Abs([double]$p.Ka) * $N / $root), [double][int]::MaxValue) * [math]::Sign($p.Ka)
    $mExp = $p.Mb - [math]::Round($kExp * $s1[$c] / ($N * 32768.0))
    $k = & $kms 0 0 $c; $m = & $kms 0 1 $c; $sv = & $kms 0 2 $c
    $rel = [math]::Abs($k - $kExp) / [math]::Max([math]::Abs($kExp), 1); $kWorst = [math]::Max($kWorst, $rel)
    if ($rel -gt 1e-6) { $kBad++ }; if ([math]::Abs($m - $mExp) -gt 2) { $mBad++ }; if ($sv -ne $p.S) { $sBad++ }
}
$result.Stage0Coefficients = [pscustomobject]@{ KOff = $kBad; KWorstRelative = $kWorst; MOffBy2 = $mBad; SOff = $sBad; SampleK = (& $kms 0 0 0); SampleKExpected = [math]::Round([math]::Abs([double](& $param 0 0).Ka) * $N / [math]::Floor([math]::Sqrt([double]$N * $s2[0] - $s1[0] * $s1[0] + [double](& $param 0 0).EpsD))) }

# Every R-input stage: K against stock statistics (approximate; R after stage 0 comes from the DSP).
$rows = foreach ($b in 0..2) { foreach ($s in 0, 2, 4) {
    $rec = $b * 6 + $s; $st = Get-KokoroChannelStats -Values (Read-KokoroCaptureTensor -Capture $caps[$b] -Name "stage$s.input") -Channels 128
    $worst = 0.0; $median = [Collections.Generic.List[double]]::new()
    for ($c = 0; $c -lt 128; $c++) {
        $p = & $param $rec $c
        $kExp = [double]$p.Ka / [math]::Sqrt($st.Variance[$c] / ($sR[$c] * $sR[$c]) + [double]$p.EpsD / ($N * $N))
        $rel = [math]::Abs((& $kms $rec 0 $c) - $kExp) / [math]::Max([math]::Abs($kExp), 1); $median.Add($rel); $worst = [math]::Max($worst, $rel)
    }
    $median.Sort(); [pscustomobject]@{ Branch = $b; Stage = $s; KRelErrorMedian = [math]::Round($median[64], 5); KRelErrorWorst = [math]::Round($worst, 5) }
} }
$result.RStageK = $rows
[pscustomobject]$result
