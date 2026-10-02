#requires -Version 7.4
# Bounded, stock-weight test of fixed-voice affine specialization.
# This synthetic activation probe does not represent a complete speech path.
[CmdletBinding()]
param(
    [string]$CheckpointPath = 'C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string]$VoicePath = 'C:\models\Kokoro-82M\voices\af_heart.pt',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../build/adain-static-specialization')
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $repo 'build'
$outDir = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outDir.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($outDir)) {
    throw 'Test output must be a new directory inside ignored build.'
}
$manifest = [IO.File]::ReadAllText((Join-Path $repo 'lib/manifest.json')) |
    ConvertFrom-Json
$pin = @($manifest.model.files | Where-Object path -CEQ 'kokoro-v1_0.pth')
if ($pin.Count -ne 1 -or
    (Get-Item -LiteralPath $CheckpointPath).Length -ne $pin[0].bytes -or
    (Get-FileHash -LiteralPath $CheckpointPath -Algorithm SHA256).Hash -cne $pin[0].sha256) {
    throw 'The checkpoint differs from its pinned identity.'
}
$reader = [scriptblock]::Create([IO.File]::ReadAllText(
    (Join-Path $repo 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
$checkpoint = & $reader.Read $CheckpointPath
$prefix = 'decoder.module.generator.resblocks.3.adain1.0.fc.'
$wName = $prefix + 'weight'
$bName = $prefix + 'bias'
if (($checkpoint.Tensors[$wName].Shape -join ',') -cne '256,128' -or
    ($checkpoint.Tensors[$bName].Shape -join ',') -cne '256') {
    throw 'The selected stock AdaIN projection shape differs.'
}
[byte[]]$wBytes = & $reader.Bytes $checkpoint $wName
[byte[]]$bBytes = & $reader.Bytes $checkpoint $bName
[float[]]$weights = [float[]]::new(256 * 128)
[float[]]$bias = [float[]]::new(256)
[Buffer]::BlockCopy($wBytes, 0, $weights, 0, $wBytes.Length)
[Buffer]::BlockCopy($bBytes, 0, $bias, 0, $bBytes.Length)
[float[]]$voice = & (Join-Path $repo 'src/models/Read-KokoroVoiceRow.ps1') `
    -VoicePath $VoicePath -PhonemeCount 7
[float[]]$decoderStyle = [float[]]::new(128)
[Array]::Copy($voice, 0, $decoderStyle, 0, 128)
$projection = & (Join-Path $repo 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
    -Style $decoderStyle -Weights $weights -Bias $bias -Channels 128

# Select a nonzero stock output channel deterministically, from pinned weights.
$channel = -1
$largest = 0.0
for ($i = 0; $i -lt 128; $i++) {
    $magnitude = [Math]::Abs([double]$projection.Gain[$i])
    if ($magnitude -gt $largest) { $largest = $magnitude; $channel = $i }
}
if ($channel -lt 0 -or $largest -lt 0.01) {
    throw 'No informative AdaIN output channel was found.'
}
$mutationScale = 1.125
[float[]]$mutatedStyle = [float[]]::new(128)
for ($i = 0; $i -lt 128; $i++) {
    $mutatedStyle[$i] = [float]([double]$decoderStyle[$i] * $mutationScale)
}
$mutatedProjection = & (Join-Path $repo 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
    -Style $mutatedStyle -Weights $weights -Bias $bias -Channels 128
$compiledControlMax = 0.0
for ($i = 0; $i -lt 128; $i++) {
    $compiledGain = 1.0 + $mutationScale *
        ([double]$projection.Gain[$i] - 1.0 - [double]$bias[$i]) + [double]$bias[$i]
    $compiledShift = $mutationScale *
        ([double]$projection.Shift[$i] - [double]$bias[128 + $i]) +
        [double]$bias[128 + $i]
    $compiledControlMax = [Math]::Max($compiledControlMax,
        [Math]::Abs($compiledGain - $mutatedProjection.Gain[$i]))
    $compiledControlMax = [Math]::Max($compiledControlMax,
        [Math]::Abs($compiledShift - $mutatedProjection.Shift[$i]))
}
if ($compiledControlMax -gt 1e-5) {
    throw 'Precomputed style-control mutation differs from stock projection.'
}
[float[]]$x1 = [float[]]@(-2, -1, 0, 1, 2, 3, 4, 5)
[float[]]$x2 = [float[]]::new($x1.Length)
for ($i = 0; $i -lt $x1.Length; $i++) { $x2[$i] = $x1[$i] + 7 }
$operator = Join-Path $repo 'src/models/ConvertTo-KokoroAdaIn.ps1'
$gain = [float[]]@($projection.Gain[$channel])
$shift = [float[]]@($projection.Shift[$channel])
[float[]]$y1 = & $operator -InputTensor $x1 -Frames 8 -Channels 1 -Gain $gain -Shift $shift
[float[]]$y2 = & $operator -InputTensor $x2 -Frames 8 -Channels 1 -Gain $gain -Shift $shift

# Fit the best per-voice static y = a*x+b on the first activation and test it
# on the shifted activation. This isolates the missing live mean reduction.
$mx = 0.0
$my = 0.0
for ($i = 0; $i -lt 8; $i++) { $mx += $x1[$i] / 8.0; $my += $y1[$i] / 8.0 }
$xx = 0.0
$xy = 0.0
for ($i = 0; $i -lt 8; $i++) {
    $dx = [double]$x1[$i] - $mx
    $xx += $dx * $dx
    $xy += $dx * ([double]$y1[$i] - $my)
}
$a = $xy / $xx
$b = $my - $a * $mx
$trainMax = 0.0
$stockShiftMax = 0.0
$staticTestMax = 0.0
for ($i = 0; $i -lt 8; $i++) {
    $trainMax = [Math]::Max($trainMax, [Math]::Abs($a * $x1[$i] + $b - $y1[$i]))
    $stockShiftMax = [Math]::Max($stockShiftMax, [Math]::Abs([double]$y1[$i] - $y2[$i]))
    $staticTestMax = [Math]::Max($staticTestMax,
        [Math]::Abs($a * $x2[$i] + $b - $y2[$i]))
}
if ($trainMax -gt 1e-5 -or $stockShiftMax -gt 1e-5 -or
    $staticTestMax -lt 0.01) {
    throw 'The static-affine counterexample did not produce the expected separation.'
}

[void][IO.Directory]::CreateDirectory($outDir)
$receipt = [ordered]@{
    Schema = 1
    Scope = 'one_stock_adain_channel_synthetic_activation_probe'
    CheckpointSHA256 = $pin[0].sha256
    Voice = 'af_heart'
    VoicePhonemeCount = 7
    Operator = 'decoder.module.generator.resblocks.3.adain1.0'
    Channel = $channel
    StockGain = [double]$gain[0]
    StockShift = [double]$shift[0]
    StyleMutationScale = $mutationScale
    CompiledStyleControlMaxAbsError = $compiledControlMax
    ActivationShift = 7
    StaticFitTrainMaxAbsError = $trainMax
    StockAdaInShiftMaxAbsError = $stockShiftMax
    StaticFitShiftedMaxAbsError = $staticTestMax
    Conclusion = 'voice_only_static_affine_is_not_equivalent_to_live_instance_statistics'
}
$path = Join-Path $outDir 'receipt.json'
[IO.File]::WriteAllText($path, (($receipt | ConvertTo-Json -Depth 4) + "`n"),
    [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Receipt = $path
    Channel = $channel
    StaticFitTrainMaxAbsError = [Math]::Round($trainMax, 8)
    StockAdaInShiftMaxAbsError = [Math]::Round($stockShiftMax, 8)
    StaticFitShiftedMaxAbsError = [Math]::Round($staticTestMax, 6)
    CompiledStyleControlMaxAbsError = [Math]::Round($compiledControlMax, 8)
}
