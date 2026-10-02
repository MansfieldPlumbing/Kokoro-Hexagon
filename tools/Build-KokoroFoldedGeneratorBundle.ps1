#requires -Version 7.4
# Builds a generator-only FP32 bundle with frozen weight_norm pairs folded.
# The output is a compiler artifact, not a runtime dependency or release file.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CheckpointPath,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [switch] $SkipFiniteScan,
    [string[]] $IncludeTensor
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $repo 'build'
$outDir = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outDir.StartsWith($build + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    [IO.Directory]::Exists($outDir)) {
    throw 'Folded generator output must be a new directory inside ignored build.'
}

$readArgs = @{ CheckpointPath = $CheckpointPath }
if ($SkipFiniteScan) { $readArgs.SkipFiniteScan = $true }
$record = & (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') @readArgs
$parameters = [Collections.Generic.Dictionary[string,float[]]]::new([StringComparer]::Ordinal)
foreach ($name in $record.Parameters.Keys) { $parameters.Add([string]$name, [float[]]$record.Parameters[$name]) }
$parameters.Add('m_source.l_linear.weight', [float[]]$record.SourceMergeWeights)
$parameters.Add('m_source.l_linear.bias', [float[]]$record.SourceMergeBias)
$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
if ($IncludeTensor) {
    foreach ($name in $IncludeTensor) {
        if (-not $parameters.ContainsKey($name)) { throw "Requested generator tensor is absent: $name" }
        [void]$selected.Add($name)
        if ($name.EndsWith('.weight_v', [StringComparison]::Ordinal)) {
            $pair = $name.Substring(0, $name.Length - '.weight_v'.Length) + '.weight_g'
            if (-not $parameters.ContainsKey($pair)) { throw "Requested weight_norm direction lacks scale: $name" }
            [void]$selected.Add($pair)
        }
    }
} else {
    foreach ($name in $parameters.Keys) { [void]$selected.Add($name) }
}

$entries = [Collections.Generic.List[object]]::new()
[long]$offset = 0
[int]$foldedPairs = 0
$consumed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
[void][IO.Directory]::CreateDirectory($outDir)
$weightsPath = Join-Path $outDir 'weights.fp32.bin'
$stream = [IO.File]::Open($weightsPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    foreach ($name in @($selected | Sort-Object -CaseSensitive)) {
        if ($consumed.Contains($name)) { continue }
        [float[]]$values = $parameters[$name]
        $sourceNames = @($name)
        $targetName = $name
        if ($name.EndsWith('.weight_v', [StringComparison]::Ordinal)) {
            $prefix = $name.Substring(0, $name.Length - '.weight_v'.Length)
            $gName = "$prefix.weight_g"
            if (-not $parameters.ContainsKey($gName)) { throw "Missing weight_norm scale for $name" }
            [float[]]$g = $parameters[$gName]
            if ($g.Length -lt 1 -or $values.Length % $g.Length) { throw "Invalid weight_norm layout for $name" }
            [int]$perOutput = $values.Length / $g.Length
            [float[]]$folded = [float[]]::new($values.Length)
            for ($output = 0; $output -lt $g.Length; $output++) {
                [int]$base = $output * $perOutput
                [double]$squares = 0
                for ($i = 0; $i -lt $perOutput; $i++) { [double]$v = $values[$base + $i]; $squares += $v * $v }
                if ($squares -eq 0) { throw "Zero-norm weight direction in $name" }
                [double]$scale = [double]$g[$output] / [Math]::Sqrt($squares)
                for ($i = 0; $i -lt $perOutput; $i++) {
                    [double]$value = [double]$values[$base + $i] * $scale
                    if (-not [double]::IsFinite($value) -or [Math]::Abs($value) -gt [float]::MaxValue) {
                        throw "Non-finite folded weight in $name"
                    }
                    $folded[$base + $i] = [float]$value
                }
            }
            $values = $folded
            $targetName = "$prefix.weight"
            $sourceNames = @($name, $gName)
            [void]$consumed.Add($gName)
            $foldedPairs++
        }
        elseif ($name.EndsWith('.weight_g', [StringComparison]::Ordinal)) {
            $prefix = $name.Substring(0, $name.Length - '.weight_g'.Length)
            if ($selected.Contains("$prefix.weight_v")) { continue }
            throw "Unpaired weight_norm scale: $name"
        }
        [byte[]]$bytes = [byte[]]::new($values.Length * 4)
        [Buffer]::BlockCopy($values, 0, $bytes, 0, $bytes.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $entries.Add([ordered]@{
            name = $targetName
            offset = $offset
            bytes = $bytes.Length
            elements = $values.Length
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            source_names = $sourceNames
            folded_weight_norm = $sourceNames.Count -eq 2
        })
        $offset += $bytes.Length
    }
}
finally { $stream.Dispose() }

$manifest = [ordered]@{
    schema = 1
    role = 'build_time_folded_generator_weight_bundle'
    source_checkpoint_sha256 = $record.CheckpointSha256
    dtype = 'float32'
    complete_generator = -not [bool]$IncludeTensor
    tensor_count = $entries.Count
    folded_weight_norm_pair_count = $foldedPairs
    bytes = $offset
    sha256 = (Get-FileHash -LiteralPath $weightsPath -Algorithm SHA256).Hash
    tensors = $entries.ToArray()
}
$manifestPath = Join-Path $outDir 'manifest.json'
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{ OutputDirectory = $outDir; Manifest = $manifestPath; TensorCount = $entries.Count; FoldedPairs = $foldedPairs; Bytes = $offset; SHA256 = $manifest.sha256 }
