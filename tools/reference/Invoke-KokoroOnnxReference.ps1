#requires -Version 7.4
# Generate isolated PC audio references from a pinned FP32 ONNX artifact.
# Historical differential evidence only; this script is not a product build edge.
[CmdletBinding()]
param(
    [string]$PlanPath = (Join-Path $PSScriptRoot '../../build/marco-polo/marco-polo-cases-24-limit-510-patience-3.json'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../build/onnx-reference'),
    [string]$StockVoicePath = 'C:\models\Kokoro-82M\voices\af_heart.pt',
    [string]$CaseId,
    [ValidateRange(1, 3)][int]$Repeats = 2
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$outDir = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outDir.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($outDir)) {
    throw 'Output must be a new directory inside the ignored build tree.'
}
$planFile = [IO.Path]::GetFullPath($PlanPath)
if (-not $planFile.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The plan must be inside the ignored build tree.'
}
$plan = [IO.File]::ReadAllText($planFile) | ConvertFrom-Json
if ($plan.Schema -ne 1 -or $plan.CaseCount -ne $plan.Cases.Count -or
    $plan.CaseCount -lt 1 -or $plan.CaseCount -gt 200 -or
    $plan.SearchPolicy.WorseTrialPatience -ne 3) {
    throw 'The deterministic case plan has an unsupported contract.'
}
$corpusHash = (Get-FileHash -LiteralPath (Join-Path $repo 'bench/corpus.json') -Algorithm SHA256).Hash
if ($corpusHash -cne $plan.SourceSHA256) { throw 'The plan corpus digest differs.' }

$revision = '1939ad2a8e416c0acfeecc08a694d14ef25f2231'
$assetDir = Join-Path $build "cache/onnx-reference-$revision"
$modelPath = Join-Path $assetDir 'model.onnx'
$voicePath = Join-Path $assetDir 'af_heart.bin'
$modelHash = '8FBEA51EA711F2AF382E88C833D9E288C6DC82CE5E98421EA61C058CE21A34CB'
$voiceHash = 'D583CCFF3CDCA2F7FAE535CB998AC07E9FCB90F09737B9A41FA2734EC44A8F0B'
if ((Get-Item -LiteralPath $modelPath).Length -ne 325532232 -or
    (Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -cne $modelHash -or
    (Get-Item -LiteralPath $voicePath).Length -ne 522240 -or
    (Get-FileHash -LiteralPath $voicePath -Algorithm SHA256).Hash -cne $voiceHash) {
    throw 'An ONNX reference artifact differs from its pinned digest.'
}
$packageRoot = Join-Path $build 'cache/onnx-reference-dotnet/packages'
$packageDir = Join-Path $packageRoot 'microsoft.ml.onnxruntime/1.23.2'
$archive = Join-Path $packageDir 'microsoft.ml.onnxruntime.1.23.2.nupkg'
$archiveDigest = Join-Path $packageDir 'microsoft.ml.onnxruntime.1.23.2.nupkg.sha512'
$sha512 = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData(
    [IO.File]::ReadAllBytes($archive)))
if ($sha512 -cne [IO.File]::ReadAllText($archiveDigest).Trim()) {
    throw 'The reference runtime package integrity check failed.'
}
[void][Reflection.Assembly]::LoadFrom((Join-Path $packageRoot 'system.numerics.tensors/9.0.0/lib/net8.0/System.Numerics.Tensors.dll'))
[void][Reflection.Assembly]::LoadFrom((Join-Path $packageRoot 'microsoft.ml.onnxruntime.managed/1.23.2/lib/net8.0/Microsoft.ML.OnnxRuntime.dll'))
[void][Runtime.InteropServices.NativeLibrary]::Load((Join-Path $packageDir 'runtimes/win-x64/native/onnxruntime.dll'))

$selected = @($plan.Cases)
if ($CaseId) {
    if ($CaseId -notmatch '^marco-[0-9]{3}$') { throw 'Invalid case identifier.' }
    $selected = @($selected | Where-Object CaseId -CEQ $CaseId)
    if ($selected.Count -ne 1) { throw 'The requested case does not exist.' }
}
$admission = & (Join-Path $repo 'src/text/Kokoro.PhonemeExpression.ps1') -RepositoryRoot $repo
$verified = & $admission.Verify
if (-not $verified.Passed -or $verified.SourceSHA256 -cne $plan.VocabularySHA256) {
    throw 'The compiled phoneme admission contract differs.'
}
$toIds = (& $admission.BuildIds).Compile()
foreach ($item in $selected) {
    if ($item.CaseId -notmatch '^marco-[0-9]{3}$' -or
        $item.Voice -cne 'af_heart' -or
        $item.PhonemeCount -lt 1 -or $item.PhonemeCount -gt 510 -or
        $item.VoiceRow -ne $item.PhonemeCount - 1 -or
        $item.PhonemeIds.Count -ne $item.PhonemeCount + 2 -or
        $item.PhonemeIds[0] -ne 0 -or $item.PhonemeIds[-1] -ne 0 -or
        $item.ReferenceStatus -cne 'requires_same_input_stock_reference') {
        throw 'A plan case failed the ONNX input boundary.'
    }
    $ids = [int[]]$toIds.Invoke([string]$item.Phonemes)
    if (($ids -join ',') -cne ($item.PhonemeIds -join ',')) {
        throw 'A plan case does not match compiled phoneme admission.'
    }
}

[void][IO.Directory]::CreateDirectory($outDir)
$voiceBytes = [IO.File]::ReadAllBytes($voicePath)
$stockVoicePin = @(([IO.File]::ReadAllText((Join-Path $repo 'lib/manifest.json')) |
    ConvertFrom-Json).model.files | Where-Object path -CEQ 'voices\af_heart.pt')
if ($stockVoicePin.Count -ne 1 -or
    (Get-FileHash -LiteralPath $StockVoicePath -Algorithm SHA256).Hash -cne $stockVoicePin[0].sha256) {
    throw 'The stock voice artifact differs from the pinned checkpoint manifest.'
}
$reader = [scriptblock]::Create([IO.File]::ReadAllText(
    (Join-Path $repo 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
$archive = & $reader.ReadTensor $StockVoicePath $stockVoicePin[0].sha256
[byte[]]$stockVoiceBytes = & $reader.Bytes $archive 'value'
if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        $voiceBytes, $stockVoiceBytes)) {
    throw 'The ONNX and pinned stock voice rows differ.'
}
$session = [Microsoft.ML.OnnxRuntime.InferenceSession]::new($modelPath)
$measurements = [Collections.Generic.List[object]]::new()
try {
    $inputNames = @($session.InputMetadata.Keys | Sort-Object)
    $outputNames = @($session.OutputMetadata.Keys)
    if (($inputNames -join ',') -cne 'input_ids,speed,style' -or
        ($outputNames -join ',') -cne 'waveform') {
        throw 'The ONNX model interface differs from the admitted contract.'
    }
    foreach ($item in $selected) {
        $idsTensor = [Microsoft.ML.OnnxRuntime.Tensors.DenseTensor[long]]::new(
            [int[]]@(1, $item.PhonemeIds.Count))
        for ($i = 0; $i -lt $item.PhonemeIds.Count; $i++) {
            $idsTensor.SetValue($i, [long]$item.PhonemeIds[$i])
        }
        [float[]]$voiceRow = [float[]]::new(256)
        [Buffer]::BlockCopy($voiceBytes, [int]$item.VoiceRow * 1024, $voiceRow, 0, 1024)
        $styleTensor = [Microsoft.ML.OnnxRuntime.Tensors.DenseTensor[float]]::new([int[]]@(1, 256))
        for ($i = 0; $i -lt 256; $i++) { $styleTensor.SetValue($i, $voiceRow[$i]) }
        $speedTensor = [Microsoft.ML.OnnxRuntime.Tensors.DenseTensor[float]]::new([int[]]@(1))
        $speedTensor.SetValue(0, [float]1)
        $inputs = [Microsoft.ML.OnnxRuntime.NamedOnnxValue[]]@(
            [Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor[long]('input_ids', $idsTensor),
            [Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor[float]('style', $styleTensor),
            [Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor[float]('speed', $speedTensor))
        [float[]]$first = $null
        for ($repeat = 1; $repeat -le $Repeats; $repeat++) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $results = $session.Run($inputs)
            $timer.Stop()
            try { [float[]]$samples = @($results[0].AsEnumerable[float]()) }
            finally { $results.Dispose() }
            if ($samples.Length -lt 1 -or $samples.Length -gt 24000 * 120) {
                throw 'The ONNX output length is outside the reference limit.'
            }
            $peak = 0.0
            $energy = 0.0
            foreach ($sample in $samples) {
                if (-not [float]::IsFinite($sample)) { throw 'The ONNX output is non-finite.' }
                $peak = [Math]::Max($peak, [Math]::Abs([double]$sample))
                $energy += [double]$sample * [double]$sample
            }
            [byte[]]$pcm = [byte[]]::new($samples.Length * 4)
            [Buffer]::BlockCopy($samples, 0, $pcm, 0, $pcm.Length)
            $stem = '{0}-r{1:d2}' -f $item.CaseId, $repeat
            $pcmPath = Join-Path $outDir "$stem.f32le"
            $stream = [IO.File]::Open($pcmPath, [IO.FileMode]::CreateNew)
            try { $stream.Write($pcm) } finally { $stream.Dispose() }
            $wavePath = Join-Path $outDir "$stem.wav"
            $waveStream = [IO.File]::Open($wavePath, [IO.FileMode]::CreateNew)
            try {
                $writer = [IO.BinaryWriter]::new($waveStream)
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
                    $writer.Write([int]$samples.Length)
                    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
                    $writer.Write([int]$pcm.Length)
                    $writer.Write($pcm)
                } finally { $writer.Dispose() }
            } finally { $waveStream.Dispose() }
            $repeatMaxDelta = $null
            $repeatSnrDb = $null
            $sameLength = $null
            if ($null -eq $first) { $first = $samples }
            else {
                $sameLength = $first.Length -eq $samples.Length
                if ($sameLength) {
                    $diffEnergy = 0.0
                    $repeatMaxDelta = 0.0
                    for ($i = 0; $i -lt $samples.Length; $i++) {
                        $delta = [double]$first[$i] - [double]$samples[$i]
                        $repeatMaxDelta = [Math]::Max($repeatMaxDelta, [Math]::Abs($delta))
                        $diffEnergy += $delta * $delta
                    }
                    if ($diffEnergy -gt 0) {
                        $repeatSnrDb = [Math]::Round(10 * [Math]::Log10($energy / $diffEnergy), 3)
                    }
                }
            }
            $measurements.Add([pscustomobject]@{
                CaseId = [string]$item.CaseId
                Repeat = $repeat
                PhonemeCount = [int]$item.PhonemeCount
                Samples = $samples.Length
                AudioSeconds = [Math]::Round($samples.Length / 24000.0, 4)
                InferenceMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 3)
                Peak = [Math]::Round($peak, 6)
                Rms = [Math]::Round([Math]::Sqrt($energy / $samples.Length), 6)
                PcmSha256 = (Get-FileHash -LiteralPath $pcmPath -Algorithm SHA256).Hash
                RepeatSameLength = $sameLength
                RepeatMaxAbsDelta = $repeatMaxDelta
                RepeatSnrDb = $repeatSnrDb
            })
        }
    }
} finally { $session.Dispose() }

$receipt = [ordered]@{
    Schema = 1
    Role = 'historical_onnx_differential_reference'
    ModelRevision = $revision
    ModelSHA256 = $modelHash
    VoiceSHA256 = $voiceHash
    StockVoiceExact = $true
    OnnxRuntimeVersion = '1.23.2'
    PlanSHA256 = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash
    SampleRate = 24000
    Measurements = $measurements.ToArray()
}
$receiptPath = Join-Path $outDir 'receipt.json'
$receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    (($receipt | ConvertTo-Json -Depth 7) + "`n"))
[IO.File]::WriteAllBytes($receiptPath, $receiptBytes)
[pscustomobject]@{
    Receipt = $receiptPath
    Cases = $selected.Count
    Runs = $measurements.Count
    RepeatSameLength = @($measurements | Where-Object RepeatSameLength -eq $false).Count -eq 0
    RepeatDifferentWaveform = @($measurements | Where-Object { $_.Repeat -gt 1 -and $_.RepeatMaxAbsDelta -gt 0 }).Count
}
