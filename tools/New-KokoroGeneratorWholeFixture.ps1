#requires -Version 7.4
<# .SYNOPSIS
Joins the 10x half and the 60x half + tail fixtures for Kokoro.Generator60x16Run.ps1 -Whole (decoder output and har to PCM).
.DESCRIPTION
The 60x front fixture must take the 10x stage's output scales as its ups[1] input scales
(tools/New-KokoroGeneratorFront16Fixture.ps1 -UpInputScaleFixture), since the job feeds LeakyReLU(0.1) of the 10x mean
straight into ups[1].
  activations.bin  the 10x inputs (decoder output, phase-major har planes), then the 60x har high and low planes
                   (the 60x front's ups[1] input planes are left out; the job computes them)
  weights.bin      the 10x weights, then the 60x + tail weights
  tables.bin       the 10x records, then the 60x + tail records
  expected-pcm-f32.bin  the stock PCM
#>
[CmdletBinding()]
param(
    # tools/New-KokoroGeneratorStageTailFixture.ps1 output for the 10x half (-FrontFixture of the 10x front).
    [Parameter(Mandatory)][string] $TenFixture,
    # tools/New-KokoroGeneratorStageTailFixture.ps1 output for the 60x half and tail, built from -FrontFixture.
    [Parameter(Mandatory)][string] $SixtyFixture,
    [Parameter(Mandatory)][string] $FrontFixture,
    [Parameter(Mandatory)][string] $OutputDirectory,
    # tools/New-KokoroHarmonicSource16Fixture.ps1 output (Kokoro.Generator60x16Run.ps1 -Whole -Source): the inputs are the
    # decoder output, then f0 and z; har is computed on the DSP, so neither half's har planes are inputs. The source's
    # weights and records follow the halves'.
    [string] $SourceFixture,
    # tools/New-KokoroDecoderFixture.ps1 output (with -SourceFixture; Kokoro.Generator60x16Run.ps1 -Whole -Source -Decoder): the job
    # computes the decoder output, so the inputs are the source's then the decoder's (asr, F0_curve, N_curve); the decoder's
    # weights and tables follow the source's. Its decoder output must be in the 10x front's DecoderScales.
    [string] $DecoderFixture
)
$ErrorActionPreference = 'Stop'
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)) { throw 'Use a new directory in build/.' }
$tenDir = [IO.Path]::GetFullPath($TenFixture); $sixtyDir = [IO.Path]::GetFullPath($SixtyFixture); $frontDir = [IO.Path]::GetFullPath($FrontFixture)
$ten = Get-Content -LiteralPath (Join-Path $tenDir 'fixture.json') -Raw | ConvertFrom-Json
$sixty = Get-Content -LiteralPath (Join-Path $sixtyDir 'fixture.json') -Raw | ConvertFrom-Json
$front = Get-Content -LiteralPath (Join-Path $frontDir 'fixture.json') -Raw | ConvertFrom-Json
foreach ($pair in @(@($tenDir, $ten), @($sixtyDir, $sixty), @($frontDir, $front))) {
    foreach ($f in $pair[1].Files) { if ((Get-FileHash (Join-Path $pair[0] $f.Name)).Hash -ne $f.SHA256) { throw "Fixture file changed: $($f.Name)" } }
}
if ($sixty.Graph -ne 'Generator60x16Tail' -or $ten.Graph -ne 'Generator60x16') { throw 'Expected a 10x stage fixture and a 60x stage + tail fixture.' }
if (-not $front.UpInputScaleFixture -or [IO.Path]::GetFullPath($front.UpInputScaleFixture) -ne [IO.Path]::GetFullPath($ten.StageFixture)) { throw 'The 60x front fixture does not take the 10x stage output scales.' }
if ((Get-FileHash (Join-Path $sixtyDir 'activations.bin')).Hash -ne (Get-FileHash (Join-Path $frontDir 'inputs.bin')).Hash) { throw 'The 60x fixture was joined from another front fixture.' }
if ([int]$front.UpFrames -ne [int]$ten.Frames + 1 -or [int]$sixty.Frames -ne 6 * [int]$ten.Frames + 1) { throw 'Frame counts do not chain.' }
$harBytes = 2L * [int]$sixty.Tiles * 4096
$read = { param([string]$d, [string]$n) [IO.File]::ReadAllBytes((Join-Path $d $n)) }
$cat = { param([byte[]]$a, [byte[]]$b, [long]$bBytes) $c = [byte[]]::new($a.Length + $bBytes); [Array]::Copy($a, $c, $a.Length); [Array]::Copy($b, 0, $c, $a.Length, $bBytes); , $c }
$sixtyAct = & $read $sixtyDir 'activations.bin'
if ($sixtyAct.Length -ne $harBytes + 2L * [int]$front.UpTiles * 16384) { throw 'Unexpected 60x input size.' }
[void][IO.Directory]::CreateDirectory($out)
if ($SourceFixture) {
    $srcDir = [IO.Path]::GetFullPath($SourceFixture); $src = Get-Content -LiteralPath (Join-Path $srcDir 'fixture.json') -Raw | ConvertFrom-Json
    foreach ($f in $src.Files) { if ((Get-FileHash (Join-Path $srcDir $f.Name)).Hash -ne $f.SHA256) { throw "Fixture file changed: $($f.Name)" } }
    if ([int]$src.Frames -ne [int]$sixty.Frames) { throw 'The source fixture frames differ.' }
    $decBytes = [long][math]::Ceiling([int]$ten.Frames / 10 / 32) * 32768
    $tenAct = & $read $tenDir 'activations.bin'; $srcAct = & $read $srcDir 'activations.bin'
    if ($DecoderFixture) {
        $decDir = [IO.Path]::GetFullPath($DecoderFixture); $dec = Get-Content -LiteralPath (Join-Path $decDir 'fixture.json') -Raw | ConvertFrom-Json
        foreach ($f in $dec.Files) { if ((Get-FileHash (Join-Path $decDir $f.Name)).Hash -ne $f.SHA256) { throw "Fixture file changed: $($f.Name)" } }
        if (2 * [int]$dec.Frames * 10 -ne [int]$ten.Frames) { throw 'The decoder fixture frames do not give the 10x frames.' }
        $decAct = & $read $decDir 'activations.bin'
        $actBytes = [byte[]]::new($srcAct.Length + $decAct.Length); [Array]::Copy($srcAct, $actBytes, $srcAct.Length); [Array]::Copy($decAct, 0, $actBytes, $srcAct.Length, $decAct.Length)
    } else {
    $actBytes = [byte[]]::new($decBytes + $srcAct.Length); [Array]::Copy($tenAct, $actBytes, $decBytes); [Array]::Copy($srcAct, 0, $actBytes, $decBytes, $srcAct.Length)
    }
    [IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), $actBytes)
    foreach ($n in 'weights.bin', 'tables.bin') { $b = & $read $sixtyDir $n; $ab = & $cat (& $read $tenDir $n) $b $b.Length; $sb = & $read $srcDir $n; $all = & $cat $ab $sb $sb.Length; if ($DecoderFixture) { $db = & $read $decDir $n; $all = & $cat $all $db $db.Length }; [IO.File]::WriteAllBytes((Join-Path $out $n), $all) }
} else {
[IO.File]::WriteAllBytes((Join-Path $out 'activations.bin'), (& $cat (& $read $tenDir 'activations.bin') $sixtyAct $harBytes))
foreach ($n in 'weights.bin', 'tables.bin') { $b = & $read $sixtyDir $n; [IO.File]::WriteAllBytes((Join-Path $out $n), (& $cat (& $read $tenDir $n) $b $b.Length)) }
}
[IO.File]::WriteAllBytes((Join-Path $out 'expected-pcm-f32.bin'), (& $read $sixtyDir 'expected-pcm-f32.bin'))
$files = @(Get-ChildItem -LiteralPath $out -File | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Length; SHA256 = (Get-FileHash $_.FullName).Hash } })
[ordered]@{ Graph = 'Generator16Whole'; Frames = $sixty.Frames; Tiles = $sixty.Tiles; TenFrames = $ten.Frames; Samples = $sixty.Samples
    TenFixture = $tenDir; SixtyFixture = $sixtyDir; FrontFixture = $frontDir; SourceFixture = $(if ($SourceFixture) { [IO.Path]::GetFullPath($SourceFixture) } else { $null }); DecoderFixture = $(if ($DecoderFixture) { [IO.Path]::GetFullPath($DecoderFixture) } else { $null }); Files = $files } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'fixture.json') -Encoding utf8NoBOM
[pscustomobject]@{ Directory = $out; Frames = $sixty.Frames; TenFrames = $ten.Frames }
