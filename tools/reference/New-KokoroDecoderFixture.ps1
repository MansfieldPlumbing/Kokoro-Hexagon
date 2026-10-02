#requires -Version 7.4
# Bounded stock decoder boundary fixture, ending before the learned generator.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputDirectory,
    [switch] $Trace)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) { throw 'Decoder fixtures must remain under repository build.' }
[void][IO.Directory]::CreateDirectory($output)
$manifest = Get-Content -LiteralPath (Join-Path $root 'lib/manifest.json') -Raw | ConvertFrom-Json
$inputRoot = Join-Path $root ('build/inputs/kokoro/' + $manifest.model.revision)
$models = Join-Path $root 'src/models'
$weights = & (Join-Path $models 'Read-KokoroDecoderWeights.ps1') `
    -CheckpointPath (Join-Path $inputRoot 'kokoro-v1_0.pth') -SkipFiniteScan
$voice = & (Join-Path $models 'Read-KokoroVoiceRow.ps1') `
    -VoicePath (Join-Path $inputRoot 'voices/af_heart.pt') -PhonemeCount 7
$style = [float[]]::new(128)
[Array]::Copy($voice, 0, $style, 0, 128)
$text = [float[]]::new(1024)
for ($i = 0; $i -lt $text.Length; $i++) { $text[$i] = [float](0.1 * [Math]::Sin($i * 0.03)) }
$f0 = [float[]]@(91, 92, 93, 94)
$noise = [float[]]@(0.1, 0.2, 0.3, 0.4)
$prelude = & (Join-Path $models 'Invoke-KokoroDecoderPrelude.ps1') `
    -AlignedTextFeatures $text -F0 $f0 -N $noise -Parameters $weights.PreludeParameters -Frames 2
$traceArguments = @{}
if ($Trace) { $traceArguments.TraceDirectory = (Join-Path $output 'decoder-trace') }
$core = & (Join-Path $models 'Invoke-KokoroDecoderCore.ps1') `
    -Prelude $prelude -Style $style -Parameters $weights.CoreParameters @traceArguments
foreach ($entry in @(@('text', $text), @('f0', $f0), @('noise', $noise),
        @('encode', $prelude.EncodeInput), @('asr', $prelude.AsrResidual), @('core', $core.Features))) {
    $bytes = [byte[]]::new(4 * $entry[1].Length)
    [Buffer]::BlockCopy($entry[1], 0, $bytes, 0, $bytes.Length)
    $stream = [IO.File]::Open((Join-Path $output "decoder.$($entry[0]).f32"),
        [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
