#requires -Version 7.4
<#
.SYNOPSIS
Windows reference for a fixed-point Snake evaluated in phase turns, against stock captures.

.DESCRIPTION
Stock Snake (hexgrad/kokoro dfb907a02bba8152ca444717ca5d78747ccb4bec, istftnet.py
AdaINResBlock1.forward): s = y + sin(a*y)^2 / a. With the phase in turns, P = a*y/pi,

    s = (pi/a) * (P + (1 - cos(2*pi*P)) / (2*pi)).

P is one signed fixed-point register (PhaseBits fractional bits). Its fractional part is
the cos argument, so wraparound is the range reduction. 1 - cos is a six-term even
polynomial in theta^2 on [0, pi/2] with Q30 coefficients, using the symmetries of cos to
fold [0, 1) turns onto [0, 1/4]. Integer arithmetic uses 64-bit products with rounding
shifts at the stated binary points. Captured stock Snake inputs (AdaIN outputs) and
outputs (conv inputs) are compared; nothing else of the model is computed here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]] $CaptureDirectory,
    [ValidateRange(10, 28)][int] $PhaseBits = 24,
    [string[]] $Stage = @('resblocks.3','resblocks.4','resblocks.5'),
    [ValidateRange(1, 1000000)][int] $MaxFrames = 1000000,
    # Evaluate 1 - cos from the top 16 fractional phase bits in Q15/Q14 halfword arithmetic
    # (HVX vmpy(Vu.h,Vv.h):<<1:rnd:sat semantics); the linear phase term stays 32-bit.
    [switch] $CosHalfword,
    # Instead of the polynomial: 16-entry Q15 cos/sin tables on the top 4 phase bits (one vlut16 each),
    # small-angle cos/sin of the centered remainder, combined as cos(H+L) = cosH cosL - sinH sinL.
    [switch] $CosTable,
    [Parameter(Mandatory)][string] $ReportPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# pwsh -File passes an array argument as one comma-joined string.
$CaptureDirectory = @($CaptureDirectory | ForEach-Object { $_ -split ',' })
$ReportPath = [IO.Path]::GetFullPath($ReportPath)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')) + [IO.Path]::DirectorySeparatorChar
if (-not $ReportPath.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $ReportPath)) { throw 'Use a new report file inside build/' }
$Stage = @($Stage | ForEach-Object { $_ -split ',' })

function Read-CaptureTensor([string]$Directory, $Manifest, [string]$Name) {
    $item = $Manifest.tensors.$Name
    if ($null -eq $item) { throw "Missing captured tensor $Name" }
    $path = Join-Path $Directory $item.file
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $item.sha256) { throw "Capture tensor integrity: $Name" }
    $bytes = [IO.File]::ReadAllBytes($path)
    $values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    [pscustomobject]@{ Values = $values; Shape = [int[]]$item.shape }
}

# Q30 coefficients of (1 - cos t) = sum_k (-1)^(k+1) t^(2k) / (2k)!, k = 1..6, in z = t^2.
class SnakeTurns {
    # Returns @(signalEnergy, errorEnergy, maxAbsPhaseTurns) for one channel row.
    static [int] MulQ15([int]$a, [int]$b) {
        [long]$r = ([long]$a * $b * 2 + 32768) -shr 16
        if ($r -gt 32767) { $r = 32767 } elseif ($r -lt -32768) { $r = -32768 }
        return [int]$r
    }
    static [double[]] Row([float[]]$y, [float[]]$s, [int]$offset, [int]$frames, [double]$alpha, [int]$bits, [bool]$halfword, [bool]$table) {
        [int[]]$cosH = [int[]]::new(16); [int[]]$sinH = [int[]]::new(16)
        for ($i = 0; $i -lt 16; $i++) {
            $cosH[$i] = [math]::Min(32767, [int][math]::Round([math]::Cos(2 * [math]::PI * $i / 16) * 32768))
            $sinH[$i] = [math]::Min(32767, [int][math]::Round([math]::Sin(2 * [math]::PI * $i / 16) * 32768))
        }
        # Q14 coefficients of sin(pi/2 * u) / u in z = u^2: sum_k (-1)^(k-1) (pi/2)^(2k-1) z^(k-1) / (2k-1)!.
        [int[]]$h = [int[]]::new(5); $hf = 1.0
        for ($k = 1; $k -le 5; $k++) { if ($k -gt 1) { $hf *= (2 * $k - 2) * (2 * $k - 1) }; $h[$k - 1] = [int][math]::Round([math]::Pow(-1, $k - 1) * [math]::Pow([math]::PI / 2, 2 * $k - 1) / $hf * 16384) }
        [long]$invTwoPiQ30h = [long][math]::Round(1073741824.0 / (2 * [math]::PI))
        [long[]]$coef = [long[]]::new(6)
        $f = 1.0
        for ($k = 1; $k -le 6; $k++) {
            $f *= (2 * $k - 1) * (2 * $k)
            $coef[$k - 1] = [long][math]::Round(([math]::Pow(-1, $k + 1) / $f) * 1073741824.0)
        }
        [long]$one = [long]1
        [long]$frac = $one -shl $bits; [long]$mask = $frac - 1
        [long]$half = $frac -shr 1; [long]$quarter = $frac -shr 2
        [long]$twoPiQ28 = [long][math]::Round(2 * [math]::PI * 268435456.0)
        [long]$two = [long]2147483648
        [long]$invTwoPiQ30 = [long][math]::Round(1073741824.0 / (2 * [math]::PI))
        [long]$rb = $one -shl ($bits - 1); [long]$r28 = $one -shl 27; [long]$rv = $one -shl (59 - $bits)
        [int]$sv = 60 - $bits
        [double]$toTurns = $alpha / [math]::PI * $frac
        [double]$back = [math]::PI / $alpha / $frac
        [double]$sig = 0; [double]$err = 0; [double]$maxPhase = 0
        for ($t = 0; $t -lt $frames; $t++) {
            [long]$p = [long][math]::Round([double]$y[$offset + $t] * $toTurns)
            [double]$ap = [math]::Abs([double]$p / $frac); if ($ap -gt $maxPhase) { $maxPhase = $ap }
            if ($table) {
                [int]$gt = [int](($p -shr ($bits - 16)) -band 65535)
                [int]$hi = (($gt + 2048) -shr 12) -band 15                      # rounded top 4 bits
                [int]$lo = $gt - ($hi -shl 12); if ($lo -ge 32768) { $lo -= 65536 } elseif ($lo -lt -32768) { $lo += 65536 }
                [int]$lq = [int][math]::Round($lo * [math]::PI)                   # radians, Q15 (|L| <= pi/16)
                [int]$l2 = [SnakeTurns]::MulQ15($lq, $lq)
                [int]$cl = 32767 - ($l2 -shr 1) + [SnakeTurns]::MulQ15([SnakeTurns]::MulQ15($l2, $l2), 1365)   # 1/24
                if ($cl -gt 32767) { $cl = 32767 }
                [int]$sl = $lq - [SnakeTurns]::MulQ15([SnakeTurns]::MulQ15($lq, $l2), 5461)                       # 1/6
                [int]$ct = [SnakeTurns]::MulQ15($cosH[$hi], $cl) - [SnakeTurns]::MulQ15($sinH[$hi], $sl)
                [long]$q14t = 16384 - ($ct -shr 1)
                [long]$vt = $p + (($q14t * $invTwoPiQ30h + ([long]1 -shl (43 - $bits))) -shr (44 - $bits))
                [double]$ot = [double]$vt * $back
                [double]$rt = [double]$s[$offset + $t]
                $sig += $rt * $rt; $err += ($ot - $rt) * ($ot - $rt)
                continue
            }
            if ($halfword) {
                # Fractional turn as signed Q16; |g| folds onto [0, 1/2) (vabs.h:sat).
                [int]$g16 = [int](($p -shr ($bits - 16)) -band 65535); if ($g16 -ge 32768) { $g16 -= 65536 }
                [int]$ga = [math]::Abs($g16); if ($ga -gt 32767) { $ga = 32767 }
                # 1 - cos(2 pi g) = 1 + sin(pi/2 * u), u = 4g - 1 in Q15.
                [int]$u = ($ga - 16384) * 2
                [int]$zz = [SnakeTurns]::MulQ15($u, $u)
                [int]$a16 = $h[4]
                $a16 = $h[3] + [SnakeTurns]::MulQ15($a16, $zz)
                $a16 = $h[2] + [SnakeTurns]::MulQ15($a16, $zz)
                $a16 = $h[1] + [SnakeTurns]::MulQ15($a16, $zz)
                $a16 = $h[0] + [SnakeTurns]::MulQ15($a16, $zz)
                [long]$q14 = 16384 + [SnakeTurns]::MulQ15($a16, $u)
                [long]$vh = $p + (($q14 * $invTwoPiQ30h + ([long]1 -shl (43 - $bits))) -shr (44 - $bits))
                [double]$oh = [double]$vh * $back
                [double]$rh = [double]$s[$offset + $t]
                $sig += $rh * $rh; $err += ($oh - $rh) * ($oh - $rh)
                continue
            }
            [long]$g = $p -band $mask
            if ($g -gt $half) { $g = $frac - $g }
            [bool]$mirror = $g -gt $quarter
            if ($mirror) { $g = $half - $g }
            [long]$theta = ($g * $twoPiQ28 + $rb) -shr $bits
            [long]$z = ($theta * $theta + $r28) -shr 28
            [long]$acc = $coef[5]
            $acc = $coef[4] + (($acc * $z + $r28) -shr 28)
            $acc = $coef[3] + (($acc * $z + $r28) -shr 28)
            $acc = $coef[2] + (($acc * $z + $r28) -shr 28)
            $acc = $coef[1] + (($acc * $z + $r28) -shr 28)
            $acc = $coef[0] + (($acc * $z + $r28) -shr 28)
            [long]$q = ($acc * $z + $r28) -shr 28
            if ($mirror) { $q = $two - $q }
            [long]$v = $p + (($q * $invTwoPiQ30 + $rv) -shr $sv)
            [double]$o = [double]$v * $back
            [double]$r = [double]$s[$offset + $t]
            $sig += $r * $r; $err += ($o - $r) * ($o - $r)
        }
        return @($sig, $err, $maxPhase)
    }
}

$results = [Collections.Generic.List[object]]::new()
foreach ($dir in $CaptureDirectory) {
    $dir = [IO.Path]::GetFullPath($dir)
    $manifest = Get-Content -LiteralPath (Join-Path $dir 'capture.json') -Raw | ConvertFrom-Json
    foreach ($st in $Stage) {
        foreach ($pair in @(@('adain1','convs1','alpha1'), @('adain2','convs2','alpha2'))) {
            foreach ($k in 0..2) {
                $y = Read-CaptureTensor $dir $manifest "generator.$st.$($pair[0]).$k.output"
                $s = Read-CaptureTensor $dir $manifest "generator.$st.$($pair[1]).$k.input.0"
                $a = Read-CaptureTensor $dir $manifest "generator.$st.$($pair[2]).$k"
                $channels = $y.Shape[1]; $frames = [math]::Min($y.Shape[2], $MaxFrames)
                $signal = 0.0; $noise = 0.0; $maxPhase = 0.0
                for ($c = 0; $c -lt $channels; $c++) {
                    $r = [SnakeTurns]::Row($y.Values, $s.Values, $c * $y.Shape[2], $frames, [double]$a.Values[$c], $PhaseBits, [bool]$CosHalfword, [bool]$CosTable)
                    $signal += $r[0]; $noise += $r[1]; if ($r[2] -gt $maxPhase) { $maxPhase = $r[2] }
                }
                $snr = 10 * [math]::Log10($signal / [math]::Max($noise, 1e-300))
                $results.Add([pscustomobject]@{ Capture = Split-Path $dir -Leaf; Site = "$st.$($pair[0]).$k"; Frames = $frames; MaxPhaseTurns = [math]::Round($maxPhase, 2); SnakeSnrDb = [math]::Round($snr, 2) })
            }
        }
    }
}
[ordered]@{ Tool = 'Measure-KokoroSnakeTurns.ps1'; ToolSHA256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash; PhaseBits = $PhaseBits; CosHalfword = [bool]$CosHalfword; CosTable = [bool]$CosTable; MaxFrames = $MaxFrames; Sites = $results } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding utf8
$results | ForEach-Object { '{0} {1} {2} dB (max phase {3} turns)' -f $_.Capture, $_.Site, $_.SnakeSnrDb, $_.MaxPhaseTurns }
