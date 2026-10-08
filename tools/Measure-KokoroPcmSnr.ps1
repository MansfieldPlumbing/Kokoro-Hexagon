#requires -Version 7.4
<# .SYNOPSIS
Raw PCM SNR of a DSP job's int16 output against the stock PyTorch PCM of the same sentence.
.DESCRIPTION
No lag, gain fitting or cropping: SNR = 10 log10(sum ref^2 / sum (ref - pcm / 32768)^2) over every sample.
The output buffer holds int16 PCM at -PcmOffset; the fixture directory holds expected-pcm-f32.bin and
fixture.json (Samples). With -WavPath, also writes the DSP PCM as a 24 kHz mono WAV inside build/.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [int] $PcmOffset = 256,
    [string] $WavPath
)
$ErrorActionPreference = 'Stop'
$fx = Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$n = [int]$fx.Samples
$refBytes = [IO.File]::ReadAllBytes((Join-Path $FixtureDirectory 'expected-pcm-f32.bin'))
if ($refBytes.Length -ne 4 * $n) { throw 'Expected PCM length differs from the fixture sample count.' }
$ref = [float[]]::new($n); [Buffer]::BlockCopy($refBytes, 0, $ref, 0, $refBytes.Length)
$buf = [IO.File]::ReadAllBytes($OutputPath)
if ($buf.Length -lt $PcmOffset + 2 * $n) { throw 'Output buffer is shorter than its PCM.' }
$pcm = [int16[]]::new($n); [Buffer]::BlockCopy($buf, $PcmOffset, $pcm, 0, 2 * $n)
$sig = 0.0; $noi = 0.0; $mx = 0.0; $clip = 0
for ($i = 0; $i -lt $n; $i++) {
    $d = [double]$ref[$i] - $pcm[$i] / 32768.0; $sig += [double]$ref[$i] * $ref[$i]; $noi += $d * $d
    if ([math]::Abs($d) -gt $mx) { $mx = [math]::Abs($d) }
    if ($pcm[$i] -eq 32767 -or $pcm[$i] -eq -32768) { $clip++ }
}
if ($WavPath) {
    $build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../build')) + [IO.Path]::DirectorySeparatorChar
    $wav = [IO.Path]::GetFullPath($WavPath)
    if (-not $wav.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $wav)) { throw 'Use a new WAV path in build/.' }
    $ms = [IO.MemoryStream]::new(); $bw = [IO.BinaryWriter]::new($ms)
    $bw.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $bw.Write([int](36 + 2 * $n)); $bw.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
    $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1); $bw.Write([int]24000); $bw.Write([int]48000); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([Text.Encoding]::ASCII.GetBytes('data')); $bw.Write([int](2 * $n)); $bw.Write($buf, $PcmOffset, 2 * $n); $bw.Flush()
    [IO.File]::WriteAllBytes($wav, $ms.ToArray())
}
[pscustomobject]@{ Samples = $n; PcmSnrDb = [math]::Round(10 * [math]::Log10($sig / [math]::Max($noi, 1e-300)), 2); MaxAbsError = [math]::Round($mx, 5); ClippedSamples = $clip; PcmSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$buf[$PcmOffset..($PcmOffset + 2 * $n - 1)])) }
