#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$prelude = Join-Path $root 'src/models/Invoke-KokoroDecoderPrelude.ps1'
$stride = Join-Path $root 'src/models/Invoke-KokoroWeightNormStride2Conv1d.ps1'
$kernel = [float[]]@(0, 1, 0)
$decimated = & $stride -InputTensor ([float[]]@(1, 2, 3, 4)) `
    -WeightV $kernel -WeightG ([float[]]@(1)) -Bias ([float[]]@(0)) -Frames 4
if (($decimated -join ',') -cne '1,3') { throw 'Analytic stride-two convolution differs.' }
$asrWeights = [float[]]::new(64 * 512)
for ($channel = 0; $channel -lt 64; $channel++) {
    $asrWeights[$channel * 512] = 1
}
$parameters = @{
    'F0_conv.weight_v' = $kernel
    'F0_conv.weight_g' = [float[]]@(1)
    'F0_conv.bias' = [float[]]@(0)
    'N_conv.weight_v' = $kernel
    'N_conv.weight_g' = [float[]]@(1)
    'N_conv.bias' = [float[]]@(0)
    'asr_res.0.weight_v' = $asrWeights
    'asr_res.0.weight_g' = [float[]]::new(64)
    'asr_res.0.bias' = [float[]]::new(64)
}
$parameters['asr_res.0.weight_g'][0] = 1
$text = [float[]]::new(512 * 2)
$text[0] = 1; $text[1] = 2
$actual = & $prelude -AlignedTextFeatures $text `
    -F0 ([float[]]@(1, 2, 3, 4)) -N ([float[]]@(5, 6, 7, 8)) `
    -Parameters $parameters -Frames 2
if ($actual.EncodeInput.Length -ne 514 * 2 -or
    $actual.AsrResidual.Length -ne 64 * 2 -or
    ($actual.DownsampledF0 -join ',') -cne '1,3' -or
    ($actual.DownsampledN -join ',') -cne '5,7' -or
    $actual.AsrResidual[0] -ne 1 -or $actual.AsrResidual[1] -ne 2 -or
    $actual.EncodeInput[1024] -ne 1 -or $actual.EncodeInput[1025] -ne 3 -or
    $actual.EncodeInput[1026] -ne 5 -or $actual.EncodeInput[1027] -ne 7) {
    throw 'Analytic decoder prelude layout differs.'
}
if ($CheckpointPath) {
    $pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
        ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
    $path = (Resolve-Path -LiteralPath $CheckpointPath).Path
    if ($pin.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
        throw 'Stock checkpoint does not match the pinned digest.'
    }
    $reader = [scriptblock]::Create([IO.File]::ReadAllText(
        (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
    $checkpoint = & $reader.Read $path
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw "Stock decoder prelude tensor shape differs: $Name"
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $stock = @{}
    $shapes = @{
        'F0_conv.weight_v' = '1,1,3'; 'F0_conv.weight_g' = '1,1,1'
        'F0_conv.bias' = '1'; 'N_conv.weight_v' = '1,1,3'
        'N_conv.weight_g' = '1,1,1'; 'N_conv.bias' = '1'
        'asr_res.0.weight_v' = '64,512,1'
        'asr_res.0.weight_g' = '64,1,1'; 'asr_res.0.bias' = '64'
    }
    foreach ($entry in $shapes.GetEnumerator()) {
        $stock[$entry.Key] = & $read ('decoder.module.' + $entry.Key) $entry.Value
    }
    $stockText = [float[]]::new(512 * 2)
    for ($i = 0; $i -lt $stockText.Length; $i++) {
        $stockText[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
    }
    $stockResult = & $prelude -AlignedTextFeatures $stockText `
        -F0 ([float[]]@(91, 92, 93, 94)) -N ([float[]]@(0.1, 0.2, 0.3, 0.4)) `
        -Parameters $stock -Frames 2
    if ($stockResult.EncodeInput.Length -ne 1028 -or
        $stockResult.AsrResidual.Length -ne 128) {
        throw 'Stock decoder prelude output shape differs.'
    }
    foreach ($values in @($stockResult.EncodeInput, $stockResult.AsrResidual)) {
        foreach ($value in $values) {
            if (-not [float]::IsFinite($value)) {
                throw 'Stock decoder prelude output is non-finite.'
            }
        }
    }
}
Write-Output 'PASS: decoder prelude analytic layout and optional stock-weight gate'
