#Requires -Version 7.4
<# .SYNOPSIS
Captures the pinned stock complete generator on Windows for DSP comparison.
Python and PyTorch are reference-only; no captured output is a product model.
#>
[CmdletBinding()]
param(
    [string]$Python = 'C:\bin\micromamba\envs\mono\python.exe',
    [ValidateLength(1,510)][string]$Phonemes = 'həlˈoʊ wˈɜɹld.',
    [ValidateSet('af_heart','am_michael')][string]$Voice = 'af_heart',
    [ValidateRange(1,100)][int]$Seed = 17,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$commit = 'dfb907a02bba8152ca444717ca5d78747ccb4bec'
$vendor = 'C:\Dev\.vendor\kokoro'
$manifest = Get-Content -LiteralPath (Join-Path $root 'lib/manifest.json') -Raw | ConvertFrom-Json
if ($manifest.kokoroSource.commit -cne $commit) { throw 'Stock source pin differs.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root ('build/stock-generator-capture-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')) }
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $out.StartsWith((Join-Path $root 'build') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Captures must be in the project build directory.' }
if (Test-Path -LiteralPath $out) { throw 'Use a new capture output directory.' }
[void][IO.Directory]::CreateDirectory($out)
$archive = Join-Path $out 'stock-source.zip'
& git -C $vendor archive --format=zip "--output=$archive" $commit kokoro
if ($LASTEXITCODE) { throw 'Pinned stock source archive failed.' }
$sourceRoot = Join-Path $out 'source'
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $sourceRoot)
$sourceFiles = @()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'kokoro') -File -Filter '*.py') {
    $relative = 'kokoro/' + $file.Name
    $blob = (& git -C $vendor rev-parse "${commit}:$relative").Trim()
    if ($LASTEXITCODE) { throw 'Pinned source blob lookup failed.' }
    $actual = (& git hash-object --no-filters -- $file.FullName).Trim()
    if ($LASTEXITCODE -or $actual -cne $blob) { throw 'Extracted stock source differs from the pinned Git blob.' }
    $sourceFiles += @{ path=$relative; sha256=(Get-FileHash -LiteralPath $file.FullName).Hash; gitBlob=$blob }
}
$inputRoot = Join-Path $root ('build/inputs/kokoro/' + $manifest.model.revision)
$inputNames = @('kokoro-v1_0.pth','config.json',"voices\$Voice.pt")
$inputs = @{}
foreach ($name in $inputNames) {
    $pin = @($manifest.model.files | Where-Object path -CEQ $name)
    $file = Join-Path $inputRoot $name
    if ($pin.Count -ne 1 -or -not (Test-Path -LiteralPath $file)) { throw "Missing pinned stock input: $name" }
    if ((Get-Item -LiteralPath $file).Length -ne $pin[0].bytes -or (Get-FileHash -LiteralPath $file).Hash -cne $pin[0].sha256) { throw "Stock input integrity mismatch: $name" }
    $inputs[$name] = @{ path=$file; sha256=$pin[0].sha256 }
}
$spec = @{ sourceCommit=$commit; sourceRoot=$sourceRoot; sourceFiles=$sourceFiles; inputs=$inputs; phonemes=$Phonemes; voice=$Voice; seed=$Seed; block='decoder.generator'; output=$out; exportToolSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash }
$specPath = Join-Path $out 'capture-spec.json'
$spec | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $specPath -Encoding utf8NoBOM
& $Python (Join-Path $PSScriptRoot 'capture_stock_generator.py') --spec $specPath
if ($LASTEXITCODE) { throw 'Stock reference capture failed.' }
if (-not (Test-Path -LiteralPath (Join-Path $out 'capture.json'))) { throw 'Stock capture manifest missing.' }
Write-Output "Capture: $out"
