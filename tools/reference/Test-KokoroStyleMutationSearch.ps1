#requires -Version 7.4
# Offline ONNX control-loop probe. The product does not import either runtime.
[CmdletBinding()]
param(
    [ValidatePattern('^marco-[0-9]{3}$')][string]$CaseId = 'marco-001',
    [ValidateRange(0.75, 1.25)][double]$InitialScale = 1.125,
    [ValidateRange(0.00390625, 0.125)][double]$InitialStep = 0.0625,
    [ValidateRange(4, 24)][int]$MaxEvaluations = 16,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../build/style-mutation-search')
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$outDir = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outDir.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($outDir)) {
    throw 'The test output must be a new directory under ignored build.'
}
$planPath = Join-Path $build 'marco-polo/marco-polo-cases-24-limit-510-patience-3.json'
$plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
$item = @($plan.Cases | Where-Object CaseId -CEQ $CaseId)
if ($plan.Schema -ne 1 -or $plan.SearchPolicy.WorseTrialPatience -ne 3 -or
    $item.Count -ne 1 -or $item[0].Voice -cne 'af_heart' -or
    $item[0].PhonemeIds.Count -ne $item[0].PhonemeCount + 2 -or
    $item[0].VoiceRow -ne $item[0].PhonemeCount - 1) {
    throw 'The requested mutation case does not satisfy the admitted plan.'
}
$item = $item[0]
$referenceDir = Join-Path $build 'onnx-reference-24'
$referenceReceipt = [IO.File]::ReadAllText((Join-Path $referenceDir 'receipt.json')) | ConvertFrom-Json
$referenceRecord = @($referenceReceipt.Measurements | Where-Object {
    $_.CaseId -CEQ $CaseId -and $_.Repeat -eq 1
})
if ($referenceRecord.Count -ne 1 -or $referenceReceipt.Role -cne
    'historical_onnx_differential_reference' -or
    $referenceReceipt.PlanSHA256 -cne
    (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash) {
    throw 'The ONNX baseline receipt does not match the input plan.'
}
$referencePath = Join-Path $referenceDir "$CaseId-r01.f32le"
$referenceBytes = [IO.File]::ReadAllBytes($referencePath)
if ($referenceBytes.Length -ne $referenceRecord[0].Samples * 4 -or
    (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash -cne
    $referenceRecord[0].PcmSha256) {
    throw 'The ONNX baseline PCM differs from its receipt.'
}
[float[]]$reference = [float[]]::new($referenceBytes.Length / 4)
[Buffer]::BlockCopy($referenceBytes, 0, $reference, 0, $referenceBytes.Length)

$assetDir = Join-Path $build 'cache/onnx-reference-1939ad2a8e416c0acfeecc08a694d14ef25f2231'
$modelPath = Join-Path $assetDir 'model.onnx'
$voicePath = Join-Path $assetDir 'af_heart.bin'
if ((Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -cne
    $referenceReceipt.ModelSHA256 -or
    (Get-FileHash -LiteralPath $voicePath -Algorithm SHA256).Hash -cne
    $referenceReceipt.VoiceSHA256) {
    throw 'The pinned ONNX model or voice asset differs.'
}
$packageRoot = Join-Path $build 'cache/onnx-reference-dotnet/packages'
foreach ($package in @(
        @{ Directory = 'microsoft.ml.onnxruntime/1.23.2'; Name = 'microsoft.ml.onnxruntime.1.23.2' },
        @{ Directory = 'mathnet.numerics/5.0.0'; Name = 'mathnet.numerics.5.0.0' }
    )) {
    $dir = Join-Path $packageRoot $package.Directory
    $bytes = [IO.File]::ReadAllBytes((Join-Path $dir "$($package.Name).nupkg"))
    $expected = [IO.File]::ReadAllText((Join-Path $dir "$($package.Name).nupkg.sha512")).Trim()
    if ([Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($bytes)) -cne
        $expected) { throw 'An evaluator package failed its integrity check.' }
}
[void][Reflection.Assembly]::LoadFrom((Join-Path $packageRoot 'system.numerics.tensors/9.0.0/lib/net8.0/System.Numerics.Tensors.dll'))
[void][Reflection.Assembly]::LoadFrom((Join-Path $packageRoot 'microsoft.ml.onnxruntime.managed/1.23.2/lib/net8.0/Microsoft.ML.OnnxRuntime.dll'))
[void][Reflection.Assembly]::LoadFrom((Join-Path $packageRoot 'mathnet.numerics/5.0.0/lib/net6.0/MathNet.Numerics.dll'))
[void][Runtime.InteropServices.NativeLibrary]::Load((Join-Path $packageRoot 'microsoft.ml.onnxruntime/1.23.2/runtimes/win-x64/native/onnxruntime.dll'))

$fftSize = 1024
$fftFrames = 32
$hann = [double[]]::new($fftSize)
for ($i = 0; $i -lt $fftSize; $i++) {
    $hann[$i] = 0.5 - 0.5 * [Math]::Cos(2 * [Math]::PI * $i / ($fftSize - 1))
}
function Get-LogSpectrum {
    param([float[]]$Samples)
    if ($Samples.Length -lt $fftSize) { throw 'The audio is shorter than one FFT window.' }
    $features = [double[]]::new($fftFrames * ($fftSize / 2 + 1))
    $lastStart = $Samples.Length - $fftSize
    for ($frame = 0; $frame -lt $fftFrames; $frame++) {
        $start = [int][Math]::Round($frame * $lastStart / ($fftFrames - 1))
        $spectrum = [System.Numerics.Complex[]]::new($fftSize)
        for ($i = 0; $i -lt $fftSize; $i++) {
            $spectrum[$i] = [System.Numerics.Complex]::new(
                [double]$Samples[$start + $i] * $hann[$i], 0)
        }
        [MathNet.Numerics.IntegralTransforms.Fourier]::Forward($spectrum)
        $offset = $frame * ($fftSize / 2 + 1)
        for ($bin = 0; $bin -le $fftSize / 2; $bin++) {
            $features[$offset + $bin] = [Math]::Log(1.0 + $spectrum[$bin].Magnitude)
        }
    }
    Write-Output -NoEnumerate $features
}
$referenceSpectrum = Get-LogSpectrum $reference
$voiceBytes = [IO.File]::ReadAllBytes($voicePath)
[float[]]$stockStyle = [float[]]::new(256)
[Buffer]::BlockCopy($voiceBytes, [int]$item.VoiceRow * 1024, $stockStyle, 0, 1024)
$idsTensor = [Microsoft.ML.OnnxRuntime.Tensors.DenseTensor[long]]::new(
    [int[]]@(1, $item.PhonemeIds.Count))
for ($i = 0; $i -lt $item.PhonemeIds.Count; $i++) {
    $idsTensor.SetValue($i, [long]$item.PhonemeIds[$i])
}
$speedTensor = [Microsoft.ML.OnnxRuntime.Tensors.DenseTensor[float]]::new([int[]]@(1))
$speedTensor.SetValue(0, [float]1)

function Invoke-Candidate {
    param([double]$Scale)
    if (-not [double]::IsFinite($Scale) -or $Scale -lt 0.75 -or $Scale -gt 1.25) {
        throw 'Style scale is outside the bounded mutation range.'
    }
    $style = [Microsoft.ML.OnnxRuntime.Tensors.DenseTensor[float]]::new([int[]]@(1, 256))
    for ($i = 0; $i -lt 256; $i++) {
        $style.SetValue($i, [float]([double]$stockStyle[$i] * $Scale))
    }
    $inputs = [Microsoft.ML.OnnxRuntime.NamedOnnxValue[]]@(
        [Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor[long]('input_ids', $idsTensor),
        [Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor[float]('style', $style),
        [Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor[float]('speed', $speedTensor))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $values = $session.Run($inputs)
    $timer.Stop()
    try { [float[]]$samples = @($values[0].AsEnumerable[float]()) }
    finally { $values.Dispose() }
    if ($samples.Length -lt $fftSize -or $samples.Length -gt 24000 * 120) {
        throw 'Mutated ONNX output length is outside the reference bound.'
    }
    foreach ($sample in $samples) {
        if (-not [float]::IsFinite($sample)) { throw 'Mutated ONNX output is non-finite.' }
    }
    $spectrum = Get-LogSpectrum $samples
    $spectralSum = 0.0
    for ($i = 0; $i -lt $spectrum.Length; $i++) {
        $spectralSum += [Math]::Abs($spectrum[$i] - $referenceSpectrum[$i])
    }
    $spectralError = $spectralSum / $spectrum.Length
    $lengthError = [Math]::Abs($samples.Length - $reference.Length) / [double]$reference.Length
    $score = $spectralError + $lengthError
    $sameWaveform = $false
    if ($samples.Length -eq $reference.Length) {
        [byte[]]$raw = [byte[]]::new($samples.Length * 4)
        [Buffer]::BlockCopy($samples, 0, $raw, 0, $raw.Length)
        $sameWaveform = [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $raw, $referenceBytes)
    }
    [pscustomobject]@{
        Scale = $Scale
        Score = $score
        SpectralError = $spectralError
        LengthError = $lengthError
        Samples = $samples.Length
        InferenceMs = $timer.Elapsed.TotalMilliseconds
        WaveformExact = $sameWaveform
        Pcm = $samples
    }
}

function Save-CandidateWave {
    param([string]$Name, [float[]]$Samples)
    [byte[]]$pcm = [byte[]]::new($Samples.Length * 4)
    [Buffer]::BlockCopy($Samples, 0, $pcm, 0, $pcm.Length)
    $path = Join-Path $outDir "$Name.wav"
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
    try {
        $writer = [IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
            $writer.Write([int](48 + $pcm.Length))
            $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
            $writer.Write([int]16)
            $writer.Write([short]3)
            $writer.Write([short]1)
            $writer.Write([int]24000)
            $writer.Write([int]96000)
            $writer.Write([short]4)
            $writer.Write([short]32)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('fact'))
            $writer.Write([int]4)
            $writer.Write([int]$Samples.Length)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
            $writer.Write([int]$pcm.Length)
            $writer.Write($pcm)
        } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
    $path
}

[void][IO.Directory]::CreateDirectory($outDir)
$trials = [Collections.Generic.List[object]]::new()
$session = [Microsoft.ML.OnnxRuntime.InferenceSession]::new($modelPath)
try {
    $identity = Invoke-Candidate 1.0
    if (-not $identity.WaveformExact -or $identity.Score -ne 0) {
        throw 'A fresh unmodified ONNX run differs from the recorded baseline.'
    }
    Import-Module (Join-Path $repo 'src/control/Kokoro.DeterministicSearch.psm1') -Force
    $search = Invoke-KokoroDeterministicSearch -Evaluate ${function:Invoke-Candidate} `
        -Initial $InitialScale -Step $InitialStep -Minimum 0.75 -Maximum 1.25 `
        -MaxEvaluations $MaxEvaluations -MaxBacktracks 1 `
        -WorsePatience $plan.SearchPolicy.WorseTrialPatience
    $first = $search.Initial; $best = $search.Best; $backtracks = $search.Backtracks
    foreach ($trial in $search.Trials) {
        $result = $trial.EvaluatorResult
        $trials.Add([pscustomobject]@{
            Trial = $trial.Trial; Scale = $trial.Coordinate
            Delta = $trial.Delta; ParentScale = $trial.ParentCoordinate
            Score = $trial.Score; SpectralError = $result.SpectralError
            LengthError = $result.LengthError; Samples = $result.Samples
            InferenceMs = $result.InferenceMs; Decision = $trial.Decision
            ConsecutiveWorse = $trial.ConsecutiveWorse; Step = $trial.Step
        })
    }
    $initialWave = Save-CandidateWave 'initial' $first.Pcm
    $bestWave = Save-CandidateWave 'best' $best.Pcm
    Import-Module (Join-Path $repo 'src/control/Kokoro.DeltaMemory.psm1') -Force
    $deltaDir = Join-Path $outDir 'deltas'
    $deltaDigests = [Collections.Generic.List[string]]::new()
    foreach ($trial in $trials) {
        $parent = $trial.ParentScale.ToString('F8', [Globalization.CultureInfo]::InvariantCulture)
        $delta = [ordered]@{
            Schema = 1; DeltaId = 'voice-global-scale'; ContextId = "$CaseId-parent-$parent"
            ArtifactSHA256 = $referenceReceipt.ModelSHA256
            TransitionKind = 'style-control-probe'; ActionId = 'scale-voice-row'
            BeforeFacts = @{'oracle.verified' = $true}; GuardFacts = @{}
            Outcome = $(if ($trial.Decision -eq 'improved') {'VerifiedBenefit'}
                elseif ($trial.Decision -eq 'initial') {'Inconclusive'} else {'Regression'})
            EvidenceId = "$CaseId-trial-$($trial.Trial.ToString('D3'))"
            Sequence = $trial.Trial; ParameterDelta = [double]$trial.Delta
            PredictedCostMs = $null; ObservedCostMs = [double]$trial.InferenceMs
        }
        $deltaPath = Export-KokoroDeltaRecord -Record $delta -Directory $deltaDir
        $deltaDigests.Add([IO.Path]::GetFileNameWithoutExtension($deltaPath))
    }
    $receipt = [ordered]@{
        Schema = 1
        Role = 'offline_onnx_control_loop_probe'
        CaseId = $CaseId
        BaselinePcmSHA256 = $referenceRecord[0].PcmSha256
        InitialScale = $InitialScale
        InitialStep = $InitialStep
        WorseTrialPatience = 3
        Objective = '32 Hann-windowed 1024-point log-magnitude FFT frames plus relative sample-length error'
        BaselineSelfCheckExact = $true
        Backtracks = $backtracks
        BestScale = $best.Scale
        BestScore = $best.Score
        InitialScore = $first.Score
        InitialWave = $initialWave
        BestWave = $bestWave
        DeltaRecordSHA256s = $deltaDigests.ToArray()
        Trials = $trials.ToArray()
    }
    $receiptPath = Join-Path $outDir 'receipt.json'
    [IO.File]::WriteAllText($receiptPath,
        (($receipt | ConvertTo-Json -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        Receipt = $receiptPath
        Trials = $trials.Count
        InitialScore = [Math]::Round($first.Score, 6)
        BestScore = [Math]::Round($best.Score, 6)
        BestScale = $best.Scale
        BestWaveformExact = $best.WaveformExact
        Backtracks = $backtracks
    }
} finally { $session.Dispose() }
