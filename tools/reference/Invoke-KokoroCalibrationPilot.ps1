#requires -Version 7.4
<# .SYNOPSIS
Freezes pilot encodings from calibration captures and checks emitted holdout blocks.
#>
[CmdletBinding()]
param([string]$StudyDirectory='build/calibration-pilot-20261006',
 [string]$Python='C:\bin\micromamba\envs\mono\python.exe',
 [ValidateSet('full-range','percentile-99.9','percentile-99.99','histogram-mse')][string[]]$Methods=@('full-range','percentile-99.9','percentile-99.99','histogram-mse'),
 [ValidateSet('hold-heart','hold-michael')][string[]]$Holdouts=@('hold-heart','hold-michael'),
 [switch]$UseFrozenEncodings,
 [ValidatePattern('^[a-zA-Z0-9.-]*$')][string]$RunTag='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$study=(Resolve-Path -LiteralPath $StudyDirectory).Path
if (-not $study.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Study must be under project build/.' }
$enc=Join-Path $study 'encodings'
if (-not $UseFrozenEncodings) {
 & $Python (Join-Path $PSScriptRoot 'calibrate_resblock_ranges.py') --capture (Join-Path $root 'build/stock-resblock-capture-20261006T092246Z') --capture (Join-Path $study 'cal-michael') --output $enc
 if ($LASTEXITCODE) { throw 'Calibration failed.' }
}
$codeRelative=@(
 'integer-adain-statistics-check-20261006/KokoroAdaInStatistics',
 'integer-adain-check-20261006/KokoroAdaInIntegerCoefficients',
 'integer-adain-check-20261006/KokoroAdaInIntegerAffine',
 'integer-snake-q8-check-20261006/KokoroSnakeInteger',
 'integer-residual-check-20261006/KokoroResidualInteger',
 'real-resblock-stage0-emission-20261006/KokoroHmxConv',
 'connected-conv-d3-check-20261006/KokoroHmxConv',
 'connected-conv-d5-check-20261006/KokoroHmxConv')
$codeFiles=@($codeRelative | ForEach-Object { Join-Path $root "build/$_/emitted-code.bin" })
$index=Get-Content (Join-Path $root 'build/integer-region-artifact-index-20261006.json') -Raw | ConvertFrom-Json
# The existing checked bodies are immutable inputs to this study.
$codeHashes=@($codeFiles | ForEach-Object { @{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash} })
foreach ($file in $codeHashes) {
 $relative=[IO.Path]::GetRelativePath($root,$file.path).Replace('\','/')
 $expected=@($index.code | Where-Object path -CEQ $relative)
 if ($expected.Count -ne 1 -or $expected[0].sha256 -cne $file.sha256) { throw 'Checked emitted code changed.' }
}
function Convert-WslPath([string]$Path) { if ($Path -notmatch '^C:\\') { throw 'Expected C drive project path.' }; return '/mnt/c/'+$Path.Substring(3).Replace('\','/') }
$records=[Collections.Generic.List[object]]::new()
foreach ($holdout in $Holdouts) {
 foreach ($method in $Methods) {
  $capture=Join-Path $study $holdout
  $encoding=Join-Path $enc "$method.json"
  $scales=(Get-Content $encoding -Raw | ConvertFrom-Json -AsHashtable).scales
  $stats=Join-Path $study "$RunTag$holdout-$method-statistics"
  $fixture=Join-Path $study "$RunTag$holdout-$method-connected"
  & (Join-Path $root 'tools/New-KokoroAdaInStatisticsFixture.ps1') -CaptureDirectory $capture -InputScale $scales['stage0.input'] -OutputDirectory $stats
  & (Join-Path $root 'tools/New-KokoroResBlockIntegerFixture.ps1') -CaptureDirectory $capture -InitialStatisticsDirectory $stats -EncodingFile $encoding -OutputDirectory $fixture
  $spec=Get-Content (Join-Path $fixture 'connected-fixture.json') -Raw | ConvertFrom-Json
  & $Python (Join-Path $PSScriptRoot 'compare_integer_resblock.py') --fixture $fixture --verify-inputs
  if ($LASTEXITCODE) { throw 'Packed input verification failed.' }
  $arguments=@($codeFiles | ForEach-Object { Convert-WslPath $_ })+@((Convert-WslPath $fixture),[string]$spec.tiles,[string]$spec.frames)
  & wsl.exe --exec bash (Convert-WslPath (Join-Path $PSScriptRoot 'hmx-sim/run-resblock-integer.sh')) @arguments
  if ($LASTEXITCODE) { throw 'Connected simulator failed.' }
  & $Python (Join-Path $PSScriptRoot 'compare_integer_resblock.py') --fixture $fixture
  if ($LASTEXITCODE) { throw 'Integer contract verification failed.' }
  $result=Get-Content (Join-Path $fixture 'connected-comparison.json') -Raw | ConvertFrom-Json
  $records.Add(@{holdout=$holdout;method=$method;result=$result})
  @{codeFiles=$codeHashes;results=@($records.ToArray())} | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $study "$($RunTag)study-results.json") -Encoding utf8NoBOM
  Write-Output "Holdout $holdout, $method, final SNR $($result.finalStockFp32Error.snrDb) dB"
 }
}
