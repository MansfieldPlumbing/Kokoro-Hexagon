#requires -Version 7.4
# Small host fixtures for the stock TorchSTFT path; not model inference.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) { throw 'Spectral fixtures must remain under repository build.' }
[void][IO.Directory]::CreateDirectory($output)
foreach ($length in @(40, 41, 45)) {
    $signal = [float[]]::new($length)
    for ($i = 0; $i -lt $length; $i++) {
        $signal[$i] = [float](0.3 * [Math]::Sin(2 * [Math]::PI * $i / 7) + 0.1 * [Math]::Cos(2 * [Math]::PI * $i / 11))
    }
    $spectrum = & (Join-Path $root 'src/models/ConvertTo-KokoroStft.ps1') -Samples $signal
    $real = [float[]]::new($spectrum.Magnitude.Length)
    $imaginary = [float[]]::new($real.Length)
    for ($i = 0; $i -lt $real.Length; $i++) {
        $real[$i] = [float]($spectrum.Magnitude[$i] * [Math]::Cos($spectrum.Phase[$i]))
        $imaginary[$i] = [float]($spectrum.Magnitude[$i] * [Math]::Sin($spectrum.Phase[$i]))
    }
    $inverse = & (Join-Path $root 'src/models/ConvertFrom-KokoroStft.ps1') `
        -Magnitude $spectrum.Magnitude -Phase $spectrum.Phase -Frames $spectrum.Frames
    foreach ($entry in @(@('input', $signal), @('real', $real), @('imaginary', $imaginary),
            @('magnitude', $spectrum.Magnitude), @('phase', $spectrum.Phase), @('inverse', $inverse))) {
        $bytes = [byte[]]::new(4 * $entry[1].Length)
        [Buffer]::BlockCopy($entry[1], 0, $bytes, 0, $bytes.Length)
        $path = Join-Path $output "stft-$length.$($entry[0]).f32"
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    }
}
