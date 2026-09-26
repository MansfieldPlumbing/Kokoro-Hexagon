#requires -Version 7.4
[CmdletBinding()]
param([string] $CheckpointPath)

$ErrorActionPreference = 'Stop'
$stage = Join-Path $PSScriptRoot '../src/models/Invoke-KokoroDurationBranch.ps1'
$encoder = @{}
foreach ($suffix in @('', '_reverse')) {
    $encoder["lstms.0.weight_ih_l0$suffix"] = [float[]]::new(1024 * 640)
    $encoder["lstms.0.weight_hh_l0$suffix"] = [float[]]::new(1024 * 256)
    $encoder["lstms.0.bias_ih_l0$suffix"] = [float[]]::new(1024)
    $encoder["lstms.0.bias_hh_l0$suffix"] = [float[]]::new(1024)
}
$encoder['lstms.1.fc.weight'] = [float[]]::new(1024 * 128)
$encoder['lstms.1.fc.bias'] = [float[]]::new(1024)
$predictor = @{}
foreach ($suffix in @('', '_reverse')) {
    $predictor["weight_ih_l0$suffix"] = [float[]]::new(1024 * 640)
    $predictor["weight_hh_l0$suffix"] = [float[]]::new(1024 * 256)
    $predictor["bias_ih_l0$suffix"] = [float[]]::new(1024)
    $predictor["bias_hh_l0$suffix"] = [float[]]::new(1024)
}
$result = & $stage -TokenFeatures ([float[]]::new(2 * 512)) `
    -Style ([float[]]::new(128)) -EncoderParameters $encoder `
    -LstmParameters $predictor -DurationWeights ([float[]]::new(50 * 512)) `
    -DurationBias ([float[]]::new(50)) -TokenCount 2 -Speed 1 `
    -EncoderLayers 1
if ($result.TokenCount -ne 2 -or $result.FrameCount -ne 50 -or
    ($result.Counts -join ',') -cne '25,25' -or
    $result.EncodedTokenFeatures.Length -ne 1280 -or
    $result.AlignedPredictorFeatures.Length -ne 32000) {
    throw 'Composed duration branch shape or frame map differs.'
}
if (@($result.AlignedPredictorFeatures | Where-Object { $_ -ne 0 }).Count -ne 0) {
    throw 'Zero-parameter duration branch produced nonzero aligned features.'
}
if ($CheckpointPath) {
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
            throw 'Stock duration branch tensor shape differs.'
        }
        [byte[]]$bytes = & $reader.Bytes $checkpoint $Name
        [float[]]$values = [float[]]::new($bytes.Length / 4)
        [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
        return ,$values
    }
    $stockEncoder = @{}
    for ($layer = 0; $layer -lt 3; $layer++) {
        $lstmIndex = 2 * $layer
        $normIndex = $lstmIndex + 1
        foreach ($suffix in @('', '_reverse')) {
            foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
                $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
                    elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
                $key = "lstms.$lstmIndex.$name$suffix"
                $stockEncoder[$key] = & $read ('predictor.module.text_encoder.' + $key) $shape
            }
        }
        foreach ($suffix in @('weight', 'bias')) {
            $key = "lstms.$normIndex.fc.$suffix"
            $shape = if ($suffix -eq 'weight') { '1024,128' } else { '1024' }
            $stockEncoder[$key] = & $read ('predictor.module.text_encoder.' + $key) $shape
        }
    }
    $stockLstm = @{}
    foreach ($suffix in @('', '_reverse')) {
        foreach ($name in @('weight_ih_l0', 'weight_hh_l0', 'bias_ih_l0', 'bias_hh_l0')) {
            $shape = if ($name -eq 'weight_ih_l0') { '1024,640' }
                elseif ($name -eq 'weight_hh_l0') { '1024,256' } else { '1024' }
            $key = "$name$suffix"
            $stockLstm[$key] = & $read ('predictor.module.lstm.' + $key) $shape
        }
    }
    $stockWeight = & $read 'predictor.module.duration_proj.linear_layer.weight' '50,512'
    $stockBias = & $read 'predictor.module.duration_proj.linear_layer.bias' '50'
    $stockInput = [float[]]::new(2 * 512)
    for ($i = 0; $i -lt $stockInput.Length; $i++) {
        $stockInput[$i] = [float](0.1 * [Math]::Sin($i * 0.02))
    }
    $stock = & $stage -TokenFeatures $stockInput -Style ([float[]]::new(128)) `
        -EncoderParameters $stockEncoder -LstmParameters $stockLstm `
        -DurationWeights $stockWeight -DurationBias $stockBias `
        -TokenCount 2 -Speed 1 -EncoderLayers 3
    if ($stock.TokenCount -ne 2 -or $stock.FrameCount -lt 2 -or
        $stock.EncodedTokenFeatures.Length -ne 1280 -or
        $stock.AlignedPredictorFeatures.Length -ne [long]640 * $stock.FrameCount) {
        throw 'Stock duration branch output shape differs.'
    }
    foreach ($value in $stock.AlignedPredictorFeatures) {
        if (-not [float]::IsFinite($value)) { throw 'Stock duration branch output is non-finite.' }
    }
}
Write-Output 'PASS: composed duration encoder, LSTM, projection, aligned gather, and optional stock-weight gate'
