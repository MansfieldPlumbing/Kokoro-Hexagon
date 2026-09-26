#requires -Version 7.4
# Build a small, all-valid differential fixture for the historical QNN r0 harness.
# The PowerShell reference output is an oracle input, not a product artifact.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CheckpointPath,
    [Parameter(Mandatory)][string] $OutDir,
    [ValidateRange(2, 128)][int] $Frames = 8
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
    ConvertFrom-Json -AsHashtable).model.files | Where-Object { $_.path -ceq 'kokoro-v1_0.pth' })
if ($pin.Count -ne 1) { throw 'Stock checkpoint pin is not unique.' }
$checkpointFile = (Resolve-Path -LiteralPath $CheckpointPath).Path
if ((Get-Item -LiteralPath $checkpointFile).Length -ne [long]$pin[0].bytes -or
    (Get-FileHash -LiteralPath $checkpointFile -Algorithm SHA256).Hash -cne $pin[0].sha256) {
    throw 'Stock checkpoint does not match the pinned digest.'
}
$destination = [IO.Path]::GetFullPath($OutDir)
if (-not $destination.StartsWith(([IO.Path]::Combine($root, 'build') + [IO.Path]::DirectorySeparatorChar),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture output must be under the repository build directory.'
}
[void][IO.Directory]::CreateDirectory($destination)

# The reader is repository-owned static source, never a downloaded script.
$reader = [scriptblock]::Create([IO.File]::ReadAllText(
    (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
$checkpoint = & $reader.Read $checkpointFile
$prefix = 'decoder.module.generator.resblocks.3.'
$parameters = @{}
for ($pass = 0; $pass -lt 3; $pass++) {
    foreach ($side in 1, 2) {
        foreach ($suffix in @("adain$side.$pass.fc.weight", "adain$side.$pass.fc.bias",
                "alpha$side.$pass", "convs$side.$pass.weight_v",
                "convs$side.$pass.weight_g", "convs$side.$pass.bias")) {
            $name = $prefix + $suffix
            if (-not $checkpoint.Tensors.Contains($name)) { throw 'Stock block tensor is missing.' }
            [byte[]]$bytes = & $reader.Bytes $checkpoint $name
            if (($bytes.Length % 4) -ne 0) { throw 'Stock block tensor length is invalid.' }
            [float[]]$values = [float[]]::new($bytes.Length / 4)
            [Buffer]::BlockCopy($bytes, 0, $values, 0, $bytes.Length)
            $parameters[$suffix] = $values
        }
    }
}

$channels = 128
$style = [float[]]::new(128)
$inputTensor = [float[]]::new($channels * $Frames)
for ($channel = 0; $channel -lt $channels; $channel++) {
    for ($frame = 0; $frame -lt $Frames; $frame++) {
        $inputTensor[$channel * $Frames + $frame] = [float](
            0.17 * [Math]::Sin(($channel + 1) * 0.11 + $frame * 0.37) +
            0.03 * [Math]::Cos(($channel + 1) * 0.07 - $frame * 0.19))
    }
}
$output = & (Join-Path $root 'src/models/Invoke-KokoroAdaInResBlock1.ps1') `
    -InputTensor $inputTensor -Style $style -Frames $Frames -Channels $channels `
    -KernelSize 3 -Dilations ([int[]]@(1, 3, 5)) -Parameters $parameters
if ($output.Length -ne $inputTensor.Length) { throw 'Reference output length differs.' }
foreach ($value in $output) {
    if (-not [float]::IsFinite($value)) { throw 'Reference output is non-finite.' }
}
$affine = & (Join-Path $root 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
    -Style $style -Weights $parameters['adain1.0.fc.weight'] `
    -Bias $parameters['adain1.0.fc.bias'] -Channels $channels
[float[]]$firstAdaIn = & (Join-Path $root 'src/models/ConvertTo-KokoroAdaIn.ps1') `
    -InputTensor $inputTensor -Frames $Frames -Channels $channels `
    -Gain $affine.Gain -Shift $affine.Shift
[float[]]$firstSnake = & (Join-Path $root 'src/models/Invoke-KokoroAdaInSnake.ps1') `
    -InputTensor $firstAdaIn -Frames $Frames -Channels $channels `
    -Alpha $parameters['alpha1.0']
[float[]]$firstConv = & (Join-Path $root 'src/models/Invoke-KokoroAdaInConv1d.ps1') `
    -InputTensor $firstSnake -Frames $Frames -InputChannels $channels `
    -OutputChannels $channels -KernelSize 3 -Dilation 1 `
    -WeightV $parameters['convs1.0.weight_v'] `
    -WeightG $parameters['convs1.0.weight_g'] -Bias $parameters['convs1.0.bias']
$secondAffine = & (Join-Path $root 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
    -Style $style -Weights $parameters['adain2.0.fc.weight'] `
    -Bias $parameters['adain2.0.fc.bias'] -Channels $channels
[float[]]$secondAdaIn = & (Join-Path $root 'src/models/ConvertTo-KokoroAdaIn.ps1') `
    -InputTensor $firstConv -Frames $Frames -Channels $channels `
    -Gain $secondAffine.Gain -Shift $secondAffine.Shift
[float[]]$secondSnake = & (Join-Path $root 'src/models/Invoke-KokoroAdaInSnake.ps1') `
    -InputTensor $secondAdaIn -Frames $Frames -Channels $channels `
    -Alpha $parameters['alpha2.0']
[float[]]$secondConv = & (Join-Path $root 'src/models/Invoke-KokoroAdaInConv1d.ps1') `
    -InputTensor $secondSnake -Frames $Frames -InputChannels $channels `
    -OutputChannels $channels -KernelSize 3 -Dilation 1 `
    -WeightV $parameters['convs2.0.weight_v'] `
    -WeightG $parameters['convs2.0.weight_g'] -Bias $parameters['convs2.0.bias']
[float[]]$firstResidual = [float[]]::new($inputTensor.Length)
for ($i = 0; $i -lt $firstResidual.Length; $i++) {
    $firstResidual[$i] = [float]([double]$inputTensor[$i] + [double]$secondConv[$i])
}
$script:pass1Traces = [ordered]@{}
function Invoke-ReferencePass([float[]] $State, [int] $Pass) {
    [float[]]$next = $State
    foreach ($side in 1, 2) {
        $affine = & (Join-Path $root 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
            -Style $style -Weights $parameters["adain$side.$Pass.fc.weight"] `
            -Bias $parameters["adain$side.$Pass.fc.bias"] -Channels $channels
        [float[]]$next = & (Join-Path $root 'src/models/ConvertTo-KokoroAdaIn.ps1') `
            -InputTensor $next -Frames $Frames -Channels $channels `
            -Gain $affine.Gain -Shift $affine.Shift
        if ($Pass -eq 1) { $script:pass1Traces["AdaIn$side"] = $next }
        [float[]]$next = & (Join-Path $root 'src/models/Invoke-KokoroAdaInSnake.ps1') `
            -InputTensor $next -Frames $Frames -Channels $channels `
            -Alpha $parameters["alpha$side.$Pass"]
        if ($Pass -eq 1) { $script:pass1Traces["Snake$side"] = $next }
        if ($Pass -eq 1 -and $side -eq 1) {
            [float[]]$script:pass1ConvDilation1 = & (Join-Path $root 'src/models/Invoke-KokoroAdaInConv1d.ps1') `
                -InputTensor $next -Frames $Frames -InputChannels $channels `
                -OutputChannels $channels -KernelSize 3 -Dilation 1 `
                -WeightV $parameters["convs$side.$Pass.weight_v"] `
                -WeightG $parameters["convs$side.$Pass.weight_g"] `
                -Bias $parameters["convs$side.$Pass.bias"]
        }
        [float[]]$next = & (Join-Path $root 'src/models/Invoke-KokoroAdaInConv1d.ps1') `
            -InputTensor $next -Frames $Frames -InputChannels $channels `
            -OutputChannels $channels -KernelSize 3 `
            -Dilation $(if ($side -eq 1) { @(1, 3, 5)[$Pass] } else { 1 }) `
            -WeightV $parameters["convs$side.$Pass.weight_v"] `
            -WeightG $parameters["convs$side.$Pass.weight_g"] `
            -Bias $parameters["convs$side.$Pass.bias"]
        if ($Pass -eq 1) { $script:pass1Traces["Conv$side"] = $next }
    }
    [float[]]$sum = [float[]]::new($State.Length)
    for ($i = 0; $i -lt $sum.Length; $i++) {
        $sum[$i] = [float]([double]$State[$i] + [double]$next[$i])
    }
    return ,$sum
}
[float[]]$secondResidual = Invoke-ReferencePass $firstResidual 1

function Write-F32([string] $Name, [float[]] $Values) {
    [byte[]]$bytes = [byte[]]::new($Values.Length * 4)
    [Buffer]::BlockCopy($Values, 0, $bytes, 0, $bytes.Length)
    [IO.File]::WriteAllBytes((Join-Path $destination $Name), $bytes)
}
Write-F32 'in_z.f32' $inputTensor
Write-F32 'in_mask1.f32' ([float[]]@(1.0) * $Frames)
Write-F32 'in_style.f32' $style
Write-F32 'oracle_r0.f32' $output
Write-F32 'oracle_a1.f32' $firstAdaIn
Write-F32 'oracle_snake.f32' $firstSnake
Write-F32 'oracle_conv.f32' $firstConv
Write-F32 'oracle_a2.f32' $secondAdaIn
Write-F32 'oracle_snake2.f32' $secondSnake
Write-F32 'oracle_conv2.f32' $secondConv
Write-F32 'oracle_residual.f32' $firstResidual
Write-F32 'oracle_residual1.f32' $secondResidual
foreach ($name in $script:pass1Traces.Keys) {
    Write-F32 "oracle_p1_$name.f32" $script:pass1Traces[$name]
}
Write-F32 'oracle_p1_Conv1_dilation1.f32' $script:pass1ConvDilation1
Write-Output "PASS: stock r0 PowerShell fixture C=$channels T=$Frames, finite output"
