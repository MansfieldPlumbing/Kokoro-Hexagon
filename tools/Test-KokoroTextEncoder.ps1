#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$stage = Join-Path $root 'src/models/Invoke-KokoroTextEncoder.ps1'
$parameters = @{ 'embedding.weight' = [float[]]@(1, 0, 0, 1) }
for ($layer = 0; $layer -lt 2; $layer++) {
    $v = [float[]]::new(2 * 2 * 3)
    $v[1] = 1; $v[10] = 1
    $parameters["cnn.$layer.0.weight_v"] = $v
    $parameters["cnn.$layer.0.weight_g"] = [float[]]@(1, 1)
    $parameters["cnn.$layer.0.bias"] = [float[]]@(0, 0)
    $parameters["cnn.$layer.1.gamma"] = [float[]]@(1, 1)
    $parameters["cnn.$layer.1.beta"] = [float[]]@(0, 0)
}
foreach ($suffix in @('', '_reverse')) {
    $parameters["lstm.weight_ih_l0$suffix"] = [float[]]::new(8)
    $parameters["lstm.weight_hh_l0$suffix"] = [float[]]::new(4)
    $parameters["lstm.bias_ih_l0$suffix"] = [float[]]::new(4)
    $parameters["lstm.bias_hh_l0$suffix"] = [float[]]::new(4)
}
$actual = & $stage -TokenIds ([int[]]@(0, 1)) -Parameters $parameters `
    -Channels 2 -VocabularySize 2 -KernelSize 3 -Layers 2
if ($actual.Length -ne 4 -or @($actual | Where-Object { $_ -ne 0 }).Count -ne 0) {
    throw 'Analytic text encoder output shape or zero LSTM differs.'
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
    $prefix = 'text_encoder.module.'
    $read = {
        param([string] $Name, [string] $Shape)
        $descriptor = $checkpoint.Tensors[$prefix + $Name]
        if ($null -eq $descriptor -or ($descriptor.Shape -join ',') -cne $Shape) {
            throw 'Stock text encoder tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint ($prefix + $Name)
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $stock = @{ 'embedding.weight' = & $read 'embedding.weight' '178,512' }
    for ($layer = 0; $layer -lt 3; $layer++) {
        $stock["cnn.$layer.0.weight_v"] = & $read "cnn.$layer.0.weight_v" '512,512,5'
        $stock["cnn.$layer.0.weight_g"] = & $read "cnn.$layer.0.weight_g" '512,1,1'
        $stock["cnn.$layer.0.bias"] = & $read "cnn.$layer.0.bias" '512'
        $stock["cnn.$layer.1.gamma"] = & $read "cnn.$layer.1.gamma" '512'
        $stock["cnn.$layer.1.beta"] = & $read "cnn.$layer.1.beta" '512'
    }
    foreach ($suffix in @('', '_reverse')) {
        foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
            $shape = if ($name -eq 'weight_ih_l0') { '1024,512' }
                elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
            $key = "lstm.$name$suffix"
            $stock[$key] = & $read $key $shape
        }
    }
    $stockOutput = & $stage -TokenIds ([int[]]@(0, 43)) -Parameters $stock
    if ($stockOutput.Length -ne 1024) { throw 'Stock text encoder output shape differs.' }
    foreach ($value in $stockOutput) {
        if (-not [float]::IsFinite($value)) { throw 'Stock text encoder output is non-finite.' }
    }
}
Write-Output 'PASS: text encoder embedding, CNN, norm, LSTM, and optional stock-weight gate'
