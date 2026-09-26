#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
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
        throw "Stock F0/N tensor shape differs: $Name"
    }
    [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
    [float[]]$values = [float[]]::new($bytes.Length / 4)
    [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
    return ,$values
}
$parameters = @{}
foreach ($suffix in @('', '_reverse')) {
    foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
        $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
            elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
        $key = "shared.$name$suffix"
        $parameters[$key] = & $read ('predictor.module.' + $key) $shape
    }
}
foreach ($branch in @('F0', 'N')) {
    for ($block = 0; $block -lt 3; $block++) {
        $inputChannels = if ($block -lt 2) { 512 } else { 256 }
        $outputChannels = if ($block -eq 0) { 512 } else { 256 }
        $prefix = "$branch.$block."
        foreach ($stage in 1, 2) {
            $channels = if ($stage -eq 1) { $inputChannels } else { $outputChannels }
            $shapes = @{
                "norm$stage.fc.weight" = "$(2 * $channels),128"
                "norm$stage.fc.bias" = "$(2 * $channels)"
                "conv$stage.weight_v" = "$outputChannels,$channels,3"
                "conv$stage.weight_g" = "$outputChannels,1,1"
                "conv$stage.bias" = "$outputChannels"
            }
            foreach ($entry in $shapes.GetEnumerator()) {
                $key = $prefix + $entry.Key
                $parameters[$key] = & $read ('predictor.module.' + $key) $entry.Value
            }
        }
        if ($block -eq 1) {
            $shapes = @{
                'pool.weight_v' = '512,1,3'
                'pool.weight_g' = '512,1,1'
                'pool.bias' = '512'
                'conv1x1.weight_v' = '256,512,1'
                'conv1x1.weight_g' = '256,1,1'
            }
            foreach ($entry in $shapes.GetEnumerator()) {
                $key = $prefix + $entry.Key
                $parameters[$key] = & $read ('predictor.module.' + $key) $entry.Value
            }
        }
    }
    $parameters["${branch}_proj.weight"] = & $read "predictor.module.${branch}_proj.weight" '1,256,1'
    $parameters["${branch}_proj.bias"] = & $read "predictor.module.${branch}_proj.bias" '1'
}
$inputTensor = [float[]]::new(640 * 2)
for ($i = 0; $i -lt $inputTensor.Length; $i++) {
    $inputTensor[$i] = [float](0.1 * [Math]::Sin($i * 0.03))
}
$actual = & (Join-Path $root 'src/models/Invoke-KokoroF0NBranch.ps1') `
    -AlignedFeatures $inputTensor -Style ([float[]]::new(128)) `
    -Parameters $parameters -Frames 2
if ($actual.Frames -ne 4 -or $actual.F0.Length -ne 4 -or $actual.N.Length -ne 4) {
    throw 'Stock F0/N branch output shape differs.'
}
foreach ($value in @($actual.F0) + @($actual.N)) {
    if (-not [float]::IsFinite($value)) { throw 'Stock F0/N branch output is non-finite.' }
}
Write-Output 'PASS: stock-weight F0/N branch shape and finite-output gate'
