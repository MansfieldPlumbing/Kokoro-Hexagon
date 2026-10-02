#requires -Version 7.4
# Host-only gates. No device discovery, deployment, full scalar synthesis, or promotion.
[CmdletBinding()]
param(
    [switch] $IncludeStock,
    [string] $AssemblyPath,
    [ValidateRange(10, 1800)][int] $TimeoutSeconds = 600,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot ('../build/host-gates-' + [Guid]::NewGuid().ToString('N')))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = [IO.Path]::Combine($root, 'build')
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($output) -or [IO.File]::Exists($output)) {
    throw 'Host gate evidence requires a new directory under this repository build directory.'
}
[void][IO.Directory]::CreateDirectory($output)
$sourceRecords = @(foreach ($directory in @('src', 'tools')) {
    Get-ChildItem -LiteralPath (Join-Path $root $directory) -Recurse -File |
        Where-Object Extension -in @('.ps1', '.psm1') | ForEach-Object {
            [pscustomobject]@{
                Path = [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
                SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }
}) | Sort-Object Path
$sourceJson = ConvertTo-Json -InputObject @($sourceRecords) -Depth 3
[IO.File]::WriteAllText((Join-Path $output 'sources.json'), $sourceJson, [Text.UTF8Encoding]::new($false))
$sourceHash = (Get-FileHash -LiteralPath (Join-Path $output 'sources.json')).Hash
$executable = (Get-Process -Id $PID).Path
$gates = [Collections.Generic.List[object]]::new()
$synthetic = @(
    'ApplianceExpression', 'DspQueueLayout', 'KokoroAdaIn', 'KokoroAdaInConv1d',
    'KokoroAdaInOperatorNames', 'KokoroAdaInResBlock1', 'KokoroAdaInResBlock1d',
    'KokoroAdaInStyle', 'KokoroAlbertAttention', 'KokoroAlbertAttentionCore',
    'KokoroAlbertEmbeddings', 'KokoroAlbertEncoder', 'KokoroAlbertFeedForward',
    'KokoroAlbertLinearEmission', 'KokoroBertEncoderProjection', 'KokoroBidirectionalLstm',
    'KokoroDecoderPrelude', 'KokoroDeltaMemory', 'KokoroDepthwiseTransposeConv1d',
    'KokoroDeterministicSearch', 'KokoroDurationAdaLayerNorm', 'KokoroDurationBranch',
    'KokoroDurationEncoder', 'KokoroDurationMap', 'KokoroDurationPrediction',
    'KokoroF0NAdaInResBlock', 'KokoroFacade', 'KokoroLearnedGenerator', 'KokoroNoiseConv1d',
    'KokoroPcm', 'KokoroPhonemeToPcmContract', 'KokoroSineSource', 'KokoroSpeechSession',
    'KokoroStft', 'KokoroShortConv1d', 'KokoroStyleControlDescriptor', 'KokoroTextEncoder',
    'KokoroWeightNormConv1d', 'KokoroWeightNormTransposeConv1d',
    'ModelContract', 'ModelStore', 'NativeBinding', 'PhonemeExpression', 'PwshDownstream',
    'R0Sub0Lowering', 'SmaSpeechPlan', 'SplitBreathGroups'
)
foreach ($name in $synthetic) {
    $gates.Add([pscustomobject]@{ Name = $name; Scope = 'synthetic'; Arguments = @{} })
}
$gates.Add([pscustomobject]@{ Name = 'ProductionClosure'; Scope = 'source_policy'; Arguments = @{ Offline = $true } })
if ($IncludeStock) {
    $inputs = & (Join-Path $PSScriptRoot 'Get-KokoroModelInput.ps1') -Offline `
        -Include @('kokoro-v1_0.pth', 'voices/af_heart.pt')
    if (-not $inputs.Passed -or $inputs.Files.Count -ne 2) { throw 'Pinned stock input admission failed.' }
    $manifest = Get-Content -LiteralPath (Join-Path $root 'lib/manifest.json') -Raw | ConvertFrom-Json
    $inputRoot = Join-Path $buildRoot ('inputs/kokoro/' + $manifest.model.revision)
    $checkpoint = Join-Path $inputRoot 'kokoro-v1_0.pth'
    $voice = Join-Path $inputRoot 'voices/af_heart.pt'
    $stock = @(
        'KokoroAcousticWeights', 'KokoroAdaInCheckpoint', 'KokoroAlbertAttention',
        'KokoroAlbertEmbeddings', 'KokoroAlbertEncoder', 'KokoroAlbertFeedForward',
        'KokoroBertEncoderProjection', 'KokoroBidirectionalLstm', 'KokoroDecoderWeights',
        'KokoroDecoderPrelude', 'KokoroDecoderCore', 'KokoroDurationAdaLayerNorm',
        'KokoroDurationBranch', 'KokoroDurationEncoder', 'KokoroDurationPrediction',
        'KokoroF0NAdaInResBlock', 'KokoroF0NBranch', 'KokoroFoldedGeneratorBundle',
        'KokoroLearnedGenerator', 'KokoroNoiseConv1d', 'KokoroSineSource',
        'KokoroTextEncoder', 'KokoroWeightCoverage', 'KokoroWeightNormFold',
        'KokoroWeightNormTransposeConv1d', 'KokoroAdaInResBlock1d', 'KokoroAcousticBranches'
    )
    foreach ($name in $stock) {
        $gates.Add([pscustomobject]@{ Name = $name; Scope = 'stock_bounded'; Arguments = @{ CheckpointPath = $checkpoint } })
    }
    foreach ($name in @('KokoroAdaInStaticSpecialization', 'KokoroAdaInSparseStyleControl')) {
        $gates.Add([pscustomobject]@{ Name = $name; Scope = 'stock_bounded'; Arguments = @{
            CheckpointPath = $checkpoint; VoicePath = $voice; OutputDirectory = (Join-Path $output $name)
        } })
    }
    $gates.Add([pscustomobject]@{ Name = 'KokoroVoiceRow'; Scope = 'stock_input'; Arguments = @{ VoicePath = $voice } })
}
if ($AssemblyPath) {
    $assembly = (Resolve-Path -LiteralPath $AssemblyPath).Path
    if (-not $assembly.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) { throw 'The model assembly must remain under this repository build directory.' }
    foreach ($name in @('KokoroEngineAssembly', 'KokoroEngineStore', 'KokoroSpeechSession', 'WindowsModelAssembly')) {
        $gates.Add([pscustomobject]@{ Name = $name; Scope = 'managed_artifact'; Arguments = @{ AssemblyPath = $assembly } })
    }
}
$results = [Collections.Generic.List[object]]::new()
foreach ($gate in $gates) {
    $scriptPath = Join-Path $PSScriptRoot ('Test-' + $gate.Name + '.ps1')
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Host gate source does not parse: $($gate.Name)" }
    $id = $gate.Scope + '-' + $gate.Name
    $start = [Diagnostics.ProcessStartInfo]::new($executable)
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath)) {
        $start.ArgumentList.Add($argument)
    }
    foreach ($key in @($gate.Arguments.Keys | Sort-Object)) {
        $start.ArgumentList.Add('-' + $key)
        if ($gate.Arguments[$key] -isnot [bool]) { $start.ArgumentList.Add([string]$gate.Arguments[$key]) }
        elseif (-not $gate.Arguments[$key]) { throw 'False switch arguments are not admitted.' }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) { $process.Kill($true); $process.WaitForExit() }
        $status = if (-not $finished) { 'timeout' } elseif ($process.ExitCode -eq 0) { 'passed' } else { 'failed' }
        [IO.File]::WriteAllText((Join-Path $output ($id + '.log')), $stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $output ($id + '.err')), $stderr.GetAwaiter().GetResult())
        $results.Add([pscustomobject]@{
            Name = $gate.Name; Scope = $gate.Scope; Status = $status; ExitCode = $process.ExitCode
            SourceSHA256 = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
            ElapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
        })
    }
    finally { $process.Dispose() }
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'gates.json') -Encoding utf8
    Write-Verbose "$id : $status"
}
$failed = @($results | Where-Object Status -ne 'passed')
$receipt = [ordered]@{
    Schema = 1; Scope = 'host_readiness'; GateCount = $results.Count; FailedCount = $failed.Count
    Passed = ($failed.Count -eq 0); DeviceExecuted = $false; SynthesisVerified = $false
    ManifestSHA256 = (Get-FileHash -LiteralPath (Join-Path $root 'lib/manifest.json')).Hash
    SourceSnapshotSHA256 = $sourceHash
    PowerShellVersion = $PSVersionTable.PSVersion.ToString(); Gates = @($results.ToArray())
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'receipt.json') -Encoding utf8
[pscustomobject]@{ Passed = $receipt.Passed; GateCount = $results.Count; FailedCount = $failed.Count; Receipt = (Join-Path $output 'receipt.json'); DeviceExecuted = $false }
if ($failed.Count) { throw "$($failed.Count) host gates failed; inspect the evidence directory." }
