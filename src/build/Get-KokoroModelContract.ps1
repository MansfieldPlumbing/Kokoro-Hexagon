# Extract the current parsed decoder contract from the legacy appliance build.
# Complete remains false until the admitted graph spans phoneme IDs to PCM.
[CmdletBinding()]
param(
    [string] $RepositoryRoot = [IO.Path]::GetFullPath(
        [IO.Path]::Combine($PSScriptRoot, '..', '..'))
)

Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$graphPath = [IO.Path]::Combine($root, 'New-KokoroDecoderGraph.ps1')
$lowerPath = [IO.Path]::Combine($root, 'src', 'lower', 'Lower-Model.ps1')
foreach ($path in $graphPath, $lowerPath) {
    if (-not [IO.File]::Exists($path)) { throw "Required Kokoro build source is missing: $path" }
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $graphPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw "Kokoro decoder contract has $($parseErrors.Count) parse error(s)."
}

$nodes = @(& $lowerPath -Model $ast.GetScriptBlock())
$expected = @(
    'KokoroFront|@asr,@F0_curve,@N,@style,@mask,@capacity',
    'KokoroGenerator|%0,@gb,@har8,@mask,@mask8,@capacity'
)
$actual = @($nodes | ForEach-Object { $_.Op + '|' + ($_.Inputs -join ',') })
if (($actual -join "`n") -cne ($expected -join "`n")) {
    throw 'Kokoro decoder contract changed unexpectedly.'
}

$json = $nodes | ConvertTo-Json -Depth 6 -Compress
[byte[]] $jsonBytes = [Text.Encoding]::UTF8.GetBytes($json)
$hash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($jsonBytes))

[pscustomobject]@{
    PSTypeName = 'Kokoro.Build.ModelContract'
    Schema = 1
    Scope = 'parsed-decoder-contract'
    Complete = $false
    GraphSHA256 = $hash
    Controls = [string[]]@(
        'asr', 'F0_curve', 'N', 'style', 'gb', 'har8', 'mask', 'mask8', 'capacity')
    Nodes = $nodes.Count
}
