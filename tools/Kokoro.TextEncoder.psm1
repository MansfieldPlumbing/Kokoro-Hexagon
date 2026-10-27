#requires -Version 7.7
Set-StrictMode -Version Latest
$script:EncoderState = $null

class KokoroEncoderCaseResult {
    [string] $Name
    [int] $Tokens
    [float] $MaxAbsError
    [double] $WarmMilliseconds
}

function Initialize-KokoroTextEncoder {
    param([Parameter(Mandatory)][string] $CheckpointPath)
    if ($null -ne $script:EncoderState) { return $script:EncoderState }
    $checkpointHash = '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4'
    if ((Get-FileHash -LiteralPath $CheckpointPath).Hash -cne $checkpointHash) { throw 'Checkpoint integrity mismatch.' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    # The pinned single-file PSLowering compiler (as Invoke-HexagonDevelopment.ps1 pins it), cached under build/ by hash.
    $loweringCommit = 'bb0f67a2bf16e54086c35ff96c0d8a5e523f0519'
    $loweringHash = '6900FC735D5F463ECFDB0241B326D959CF7A8B8A252B56B1A7734F20D3BD9BD6'
    $compiler = Join-Path $root "build/lowered-hexagon/compiler/$loweringHash/Export-LoweredAssembly.ps1"
    if (-not [IO.File]::Exists($compiler)) {
        $loweringBytes = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/MansfieldPlumbing/PSLowering/$loweringCommit/Export-LoweredAssembly.ps1" -UseBasicParsing).RawContentStream.ToArray()
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($loweringBytes)) -cne $loweringHash) { throw 'Pinned PSLowering compiler hash mismatch.' }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($compiler)); [IO.File]::WriteAllBytes($compiler, $loweringBytes)
    }
    if ((Get-FileHash -LiteralPath $compiler).Hash -cne $loweringHash) { throw 'Compiler integrity mismatch.' }
    $source = Join-Path $root 'src/frontend/Kokoro.TextEncoder.ps1'
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $directory = Join-Path $root "build/frontend/encoder/$sourceHash/$loweringCommit"
    [void][IO.Directory]::CreateDirectory($directory)
    $dll = Join-Path $directory 'Kokoro.TextEncoder.dll'; $digestPath = $dll + '.sha256'
    if (-not (Test-Path -LiteralPath $dll)) {
        $null = & $compiler -SourcePath $source -ClassName KokoroTextEncoder -OutputPath $dll -Deterministic
        [IO.File]::WriteAllText($digestPath, (Get-FileHash -LiteralPath $dll).Hash)
    }
    if (-not (Test-Path -LiteralPath $digestPath) -or (Get-FileHash -LiteralPath $dll).Hash -cne [IO.File]::ReadAllText($digestPath)) { throw 'Compiled encoder integrity mismatch.' }
    $admission = & $compiler -Mode Inspect -AssemblyPath $dll
    if (-not $admission.ClrOnlyAdmitted -or $admission.AssemblyReferences.Count -ne 1 -or $admission.AssemblyReferences[0] -cne 'System.Private.CoreLib') { throw 'Encoder is not CoreLib-only.' }
    $assembly = [Reflection.Assembly]::LoadFrom($dll); $type = $assembly.GetType('KokoroTextEncoder', $true)
    $engine = [Activator]::CreateInstance($type)
    $fold = $type.GetMethod('FoldWeightNorm').CreateDelegate([Func[float[],float[],float[]]])
    $maxError = $type.GetMethod('MaxError').CreateDelegate([Func[float[],float[],float]])
    $torchModule = Import-Module (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1') -PassThru
    $reader = $torchModule.Invoke({ [pscustomobject]@{ Read = $read; Bytes = $bytes } })[0]
    $checkpoint = & $reader.Read $CheckpointPath
    function Read-EncoderWeight([string] $Name, [int] $Count) {
        $tensor = $checkpoint.Tensors[$Name]
        if ($null -eq $tensor -or $tensor.DType -cne 'float32' -or $tensor.Count -ne $Count) { throw "Weight shape/dtype mismatch: $Name" }
        $stride = 1L
        for ($axis = $tensor.Shape.Length - 1; $axis -ge 0; $axis--) {
            if ($tensor.Stride[$axis] -ne $stride) { throw "Noncontiguous weight: $Name" }; $stride *= $tensor.Shape[$axis]
        }
        $raw = & $reader.Bytes $checkpoint $Name
        $values = [float[]]::new($Count); [Buffer]::BlockCopy($raw, 0, $values, 0, $raw.Length)
        return , $values
    }
    $prefix = 'text_encoder.module.'
    $engine.Embedding = Read-EncoderWeight ($prefix + 'embedding.weight') (178 * 512)
    $engine.ConvWeights = [float[]]::new(3 * 1310720); $engine.ConvBias = [float[]]::new(1536)
    $engine.Gamma = [float[]]::new(1536); $engine.Beta = [float[]]::new(1536)
    for ($layer = 0; $layer -lt 3; $layer++) {
        $convPrefix = $prefix + "cnn.$layer."
        $values = Read-EncoderWeight ($convPrefix + '0.weight_v') 1310720; $gain = Read-EncoderWeight ($convPrefix + '0.weight_g') 512
        $weights = $fold.Invoke($values, $gain); [Array]::Copy($weights, 0, $engine.ConvWeights, $layer * 1310720, 1310720)
        [Array]::Copy((Read-EncoderWeight ($convPrefix + '0.bias') 512), 0, $engine.ConvBias, $layer * 512, 512)
        [Array]::Copy((Read-EncoderWeight ($convPrefix + '1.gamma') 512), 0, $engine.Gamma, $layer * 512, 512)
        [Array]::Copy((Read-EncoderWeight ($convPrefix + '1.beta') 512), 0, $engine.Beta, $layer * 512, 512)
    }
    $engine.InputWeights = [float[]]::new(2 * 1024 * 512); $engine.HiddenWeights = [float[]]::new(2 * 1024 * 256)
    $engine.InputBias = [float[]]::new(2048); $engine.HiddenBias = [float[]]::new(2048)
    for ($direction = 0; $direction -lt 2; $direction++) {
        $suffix = ''; if ($direction -eq 1) { $suffix = '_reverse' }
        [Array]::Copy((Read-EncoderWeight ($prefix + 'lstm.weight_ih_l0' + $suffix) (1024 * 512)), 0, $engine.InputWeights, $direction * 1024 * 512, 1024 * 512)
        [Array]::Copy((Read-EncoderWeight ($prefix + 'lstm.weight_hh_l0' + $suffix) (1024 * 256)), 0, $engine.HiddenWeights, $direction * 1024 * 256, 1024 * 256)
        [Array]::Copy((Read-EncoderWeight ($prefix + 'lstm.bias_ih_l0' + $suffix) 1024), 0, $engine.InputBias, $direction * 1024, 1024)
        [Array]::Copy((Read-EncoderWeight ($prefix + 'lstm.bias_hh_l0' + $suffix) 1024), 0, $engine.HiddenBias, $direction * 1024, 1024)
    }
    $script:EncoderState = [pscustomobject]@{ Engine = $engine; MaxError = $maxError; Assembly = $admission; SourceSHA256 = $sourceHash; CheckpointSHA256 = $checkpointHash }
    $script:EncoderState
}

function Test-KokoroTextEncoder {
    param([Parameter(Mandatory)][string] $CheckpointPath, [Parameter(Mandatory)][string] $CaptureDirectory)
    $state = Initialize-KokoroTextEncoder -CheckpointPath $CheckpointPath
    $capture = Import-PowerShellDataFile (Join-Path $CaptureDirectory 'capture.psd1')
    foreach ($case in $capture.Cases) {
        $ids = $null; $expected = $null
        foreach ($tensor in $case.Tensors | Where-Object { $_.Name -cin @('ids', 'text-encoder') }) {
            if ($tensor.File -cnotmatch '^[A-Za-z0-9_.-]+\.bin$') { throw 'Invalid capture filename.' }
            $path = Join-Path $CaptureDirectory $tensor.File
            if ((Get-FileHash -LiteralPath $path).Hash -cne $tensor.SHA256) { throw 'Capture tensor integrity mismatch.' }
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($tensor.Name -ceq 'ids') { $ids = [int[]]::new($tensor.Shape[0]); [Buffer]::BlockCopy($bytes, 0, $ids, 0, $bytes.Length) }
            else { $expected = [float[]]::new($tensor.Shape[0] * $tensor.Shape[1]); [Buffer]::BlockCopy($bytes, 0, $expected, 0, $bytes.Length) }
        }
        if ($null -eq $ids -or $null -eq $expected -or $expected.Length -ne 512 * $ids.Length) { throw 'Missing/misaligned encoder reference.' }
        $watch = [Diagnostics.Stopwatch]::new(); $actual = $null
        for ($run = 1; $run -le 10; $run++) { $watch.Restart(); $actual = $state.Engine.Run($ids, $ids.Length); $watch.Stop() }
        $errorValue = $state.MaxError.Invoke($actual, $expected)
        $result = [KokoroEncoderCaseResult]::new(); $result.Name = $case.Name; $result.Tokens = $ids.Length
        $result.MaxAbsError = $errorValue; $result.WarmMilliseconds = $watch.Elapsed.TotalMilliseconds
        $result
        if ($errorValue -gt 0.001) { throw "Text encoder gate failed for $($case.Name): $errorValue" }
    }
}

Export-ModuleMember -Function Initialize-KokoroTextEncoder, Test-KokoroTextEncoder
