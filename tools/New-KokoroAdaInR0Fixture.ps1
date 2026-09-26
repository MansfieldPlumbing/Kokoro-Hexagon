#requires -Version 7.4
# Build a small, all-valid differential fixture for the historical QNN r0 harness.
# The PowerShell reference output is an oracle input, not a product artifact.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CheckpointPath,
    [Parameter(Mandatory)][string] $OutDir,
    [ValidateRange(2, 16)][int] $Frames = 8
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

function Write-F32([string] $Name, [float[]] $Values) {
    [byte[]]$bytes = [byte[]]::new($Values.Length * 4)
    [Buffer]::BlockCopy($Values, 0, $bytes, 0, $bytes.Length)
    [IO.File]::WriteAllBytes((Join-Path $destination $Name), $bytes)
}
Write-F32 'in_z.f32' $inputTensor
Write-F32 'in_mask1.f32' ([float[]]@(1.0) * $Frames)
Write-F32 'in_style.f32' $style
Write-F32 'oracle_r0.f32' $output
Write-Output "PASS: stock r0 PowerShell fixture C=$channels T=$Frames, finite output"
