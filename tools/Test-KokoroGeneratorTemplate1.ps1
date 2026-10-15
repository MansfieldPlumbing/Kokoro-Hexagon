#requires -Version 7.7
using namespace System.Linq.Expressions
using namespace System.Runtime.Intrinsics
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputDirectory,
    [string] $InputRepository = 'C:\Dev\Kokoro-Hexagon',
    [string] $ReferenceRepository = 'C:\Dev\Kokoro-Hexagon-v15-front-end',
    [ValidateRange(0,60)][int] $Tiles = 0,
    [ValidateRange(0,5)][int] $ResBlockIndex = 3,
    [ValidateRange(0,2)][int] $DilationIndex = 0,
    [ValidateRange(1,20)][int] $Runs = 5,
    [switch] $ConnectedConsumer,
    [ValidateSet('Lock','Smoothstep')][string] $Shape = 'Lock',
    [ValidateRange(16,64)][int] $BlockFrames = 16,
    [ValidateSet('SM8550')][string] $Soc = 'SM8550',
    [string] $Package = 'dev.mansfieldplumbing.kokoro'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Smoothstep = $Shape -ceq 'Smoothstep'
$PhaseLock = $Shape -ceq 'Lock'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $output)) { throw 'Choose a fresh output directory under this worktree build/.' }
[void][IO.Directory]::CreateDirectory($output)
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1')
Import-Module (Join-Path $PSScriptRoot 'Kokoro.Evaluator.psm1')
. (Join-Path $root 'src/jobs/Kokoro.GeneratorTemplate1Run.ps1')

function Read-TemplateFloatTensor([hashtable] $Descriptor,[string] $Directory) {
    if ($Descriptor.File -cnotmatch '^[A-Za-z0-9_.-]+\.bin$' -or $Descriptor.SHA256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Invalid preserved tensor descriptor.' }
    $path = Join-Path $Directory $Descriptor.File
    $count = 1L
    foreach ($dimension in $Descriptor.Shape) { if ($dimension -lt 1) { throw 'Invalid tensor dimension.' }; $count *= $dimension }
    if ($count -gt 268435456L -or (Get-Item -LiteralPath $path).Length -ne 4*$count -or
        (Get-FileHash -LiteralPath $path).Hash -cne $Descriptor.SHA256) { throw 'Preserved float tensor integrity mismatch.' }
    $raw = [IO.File]::ReadAllBytes($path); $values = [float[]]::new($count)
    [Buffer]::BlockCopy($raw,0,$values,0,$raw.Length)
    return ,$values
}
function Write-TemplateBinary([string] $Name,[Array] $values) {
    $bytes = [byte[]]::new([Buffer]::ByteLength($values)); [Buffer]::BlockCopy($values,0,$bytes,0,$bytes.Length)
    [IO.File]::WriteAllBytes((Join-Path $output $Name),$bytes)
}
function Copy-TemplateFrames([float[]]$values,[int]$SourceFrames,[int]$frames) {
    if ($frames -gt $SourceFrames -or $values.Length % $SourceFrames -ne 0) { throw 'Invalid frame slice.' }
    $channels = [int]($values.Length/$SourceFrames); $slice = [float[]]::new($channels*$frames)
    for ($channel=0; $channel -lt $channels; $channel++) { [Array]::Copy($values,$channel*$SourceFrames,$slice,$channel*$frames,$frames) }
    return ,$slice
}

# Reuse the exact compiled reference admitted at 68bdb38; do not compile or write in its checkout.
$referenceSource = Join-Path $ReferenceRepository 'tools/Invoke-KokoroPrecomputedDecoder.ps1'
$sourceHash = (Get-FileHash -LiteralPath $referenceSource).Hash
$referenceGate = Join-Path $ReferenceRepository 'build/precomputed-decoder-reopen-20261014/final-artifact-gate'
$referenceRows = @(Import-Clixml -LiteralPath (Join-Path $referenceGate 'part1-gate.clixml'))
$referenceDll = Join-Path $referenceGate "$sourceHash/Kokoro.OfflineRender.dll"
$referenceHash = (Get-FileHash -LiteralPath $referenceDll).Hash
if (-not @($referenceRows | Where-Object { $_.SourceSHA256 -ceq $sourceHash -and $_.AssemblySHA256 -ceq $referenceHash }).Count) {
    throw 'Compiled offline reference does not match its preserved admission.'
}
$assembly = [Reflection.Assembly]::LoadFrom($referenceDll)
$math = $assembly.GetType('OfflineRenderMath',$true); $workerType = $assembly.GetType('OfflineConvolutionWorker',$true)
$compare = $math.GetMethod('Compare').CreateDelegate([Func[float[],float[],double[]]])
$snake = $math.GetMethod('Snake').CreateDelegate([Func[float[],float[],int,float[]]])
$adaIn = $math.GetMethod('AdaIn').CreateDelegate([Func[float[],int,int,float[],float[],float[],float[],float[],float[]]])
$applyLevels = $math.GetMethod('ApplyLevels').CreateDelegate([Func[float[],int,int,float[],float[],float[],float[],float[],double[],float[]]])
$measureLevels = $math.GetMethod('MeasureLevels').CreateDelegate([Func[float[],int,int,int[],double[]]])
$residual = $math.GetMethod('Residual').CreateDelegate([Func[float[],float[],float,float[]]])
$reflect = $math.GetMethod('ReflectLeft').CreateDelegate([Func[float[],int,int,float[]]])
$fold = $math.GetMethod('FoldWeights').CreateDelegate([Func[float[],float[],float[]]])
$indicesKernel = $math.GetMethod('FrameIndices').CreateDelegate([Func[int,int,int,int,int,int,bool,int[]]])
$vectorKernel = $math.GetMethod('PackInputs').CreateDelegate([Func[float[],int[],int,int,int,int,Vector128[float][]]])
$activeKernel = $math.GetMethod('ActiveIndices').CreateDelegate([Func[int[],int,bool[]]])
$argument = [Expression]::Parameter([float],'value')
$nonfinite = [Expression]::Lambda([Predicate[float]],
    [Expression]::Not([Expression]::Call([float].GetMethod('IsFinite',[Type[]]@([float])),$argument)),[ParameterExpression[]]@($argument)).Compile()

$nodeDirectory = Join-Path $InputRepository 'build/node-capture-20261014'
$nodes = Import-PowerShellDataFile (Join-Path $nodeDirectory 'nodes.psd1')
$generatorStage = [int][Math]::Floor($ResBlockIndex/3.0)
$upNode = @($nodes.Nodes | Where-Object Name -CEQ "gen.ups$generatorStage")[0]
$noiseNode = @($nodes.Nodes | Where-Object Name -CEQ "gen.noise_res$generatorStage")[0]
$upsampled = Read-TemplateFloatTensor $upNode $nodeDirectory
$excitation = Read-TemplateFloatTensor $noiseNode $nodeDirectory
$channels = if ($generatorStage -eq 0) { 256 } else { 128 }
$positions = if ($generatorStage -eq 0) { 10 } else { 60 }
if ($Tiles -eq 0) { $Tiles = $positions*$BlockFrames/32 }
$kernelSize = @(3,7,11)[$ResBlockIndex%3]
$tapDilation = 1+2*$DilationIndex
$frames = [int]$noiseNode.Shape[2]
if ($generatorStage -eq 1) { $upsampled = $reflect.Invoke($upsampled,$channels,[int]$upNode.Shape[2]) }
$sharedInput = $residual.Invoke($upsampled,$excitation,[float]1)
$captureDirectory = Join-Path $InputRepository 'build/score-capture-20261014'
$capture = Import-PowerShellDataFile (Join-Path $captureDirectory 'capture.psd1')
$dog = @($capture.Cases | Where-Object Name -CEQ 'dog')[0]
$style = Read-TemplateFloatTensor (@($dog.Tensors | Where-Object Name -CEQ 'acoustic')[0]) $captureDirectory

$checkpointPath = Join-Path $InputRepository 'build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987/kokoro-v1_0.pth'
if ((Get-FileHash -LiteralPath $checkpointPath).Hash -cne '496DBA118D1A58F5F3DB2EFC88DBDC216E0483FC89FE6E47EE1F2C53F18AD1E4') { throw 'Checkpoint integrity mismatch.' }
$torch = Import-Module (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1') -PassThru
$reader = $torch.Invoke({[pscustomobject]@{Read=$read;Bytes=$bytes}})[0]
$checkpoint = & $reader.Read $checkpointPath
function Read-TemplateWeight([string]$Name) {
    $tensor = $checkpoint.Tensors[$Name]
    if ($null -eq $tensor -or $tensor.DType -cne 'float32') { throw "Missing float weight: $Name" }
    $stride = 1L
    for ($axis=$tensor.Shape.Length-1; $axis -ge 0; $axis--) { if ($tensor.Stride[$axis] -ne $stride) { throw 'Noncontiguous weight.' }; $stride *= $tensor.Shape[$axis] }
    $raw = & $reader.Bytes $checkpoint $Name; $values = [float[]]::new($tensor.Count)
    [Buffer]::BlockCopy($raw,0,$values,0,$raw.Length)
    return ,$values
}
$convolutionCache = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
function Invoke-TemplateReferenceConvolution([float[]]$values,[string]$Name,[int]$Dilation=1) {
    if (-not $convolutionCache.ContainsKey($Name)) {
        $weightName = $Name+'.weight'
        if ($checkpoint.Tensors.Contains($weightName)) { $convolutionWeights=Read-TemplateWeight $weightName }
        else { $weightName=$Name+'.weight_v'; $convolutionWeights=$fold.Invoke((Read-TemplateWeight $weightName),(Read-TemplateWeight ($Name+'.weight_g'))) }
        $shape = $checkpoint.Tensors[$weightName].Shape
        $convolutionBias = [float[]]::new($shape[0])
        if ($checkpoint.Tensors.Contains($Name+'.bias')) { $convolutionBias=Read-TemplateWeight ($Name+'.bias') }
        $convolutionCache.Add($Name,[pscustomobject]@{InputChannels=[int]$shape[1];OutputChannels=[int]$shape[0];Kernel=[int]$shape[2];Weights=$convolutionWeights;Bias=$convolutionBias})
    }
    $descriptor = $convolutionCache[$Name]
    if ($values.Length -ne $descriptor.InputChannels*$frames) { throw 'Reference continuation convolution shape mismatch.' }
    $outputValues = [float[]]::new($descriptor.OutputChannels*$frames)
    $padding = [int](($descriptor.Kernel-1)*$Dilation/2)
    $frameMap = $indicesKernel.Invoke($frames,$frames,$descriptor.Kernel,1,$Dilation,$padding,$false)
    $vectorInput = $vectorKernel.Invoke($values,$frameMap,$descriptor.InputChannels,$frames,$frames,$descriptor.Kernel)
    $activeTaps = $activeKernel.Invoke($frameMap,$descriptor.Kernel)
    $referenceWorkers = [Collections.Generic.List[object]]::new(); $referenceTasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
    $workerCount = [Math]::Min(4,$descriptor.OutputChannels)
    for ($workerIndex=0; $workerIndex -lt $workerCount; $workerIndex++) {
        $referenceWorker = [Activator]::CreateInstance($workerType)
        $referenceWorker.Input=$values; $referenceWorker.Output=$outputValues; $referenceWorker.Weights=$descriptor.Weights; $referenceWorker.Bias=$descriptor.Bias
        $referenceWorker.Indices=$frameMap; $referenceWorker.VectorInput=$vectorInput; $referenceWorker.ActiveTaps=$activeTaps
        $referenceWorker.InputChannels=$descriptor.InputChannels; $referenceWorker.OutputChannels=$descriptor.OutputChannels
        $referenceWorker.InputFrames=$frames; $referenceWorker.OutputFrames=$frames; $referenceWorker.Kernel=$descriptor.Kernel
        $referenceWorker.Stride=1; $referenceWorker.Dilation=$Dilation; $referenceWorker.Padding=$padding; $referenceWorker.Groups=1; $referenceWorker.Transpose=$false
        $referenceWorker.FirstChannel=[int][Math]::Floor($workerIndex*$descriptor.OutputChannels/[double]$workerCount)
        $referenceWorker.LastChannel=[int][Math]::Floor(($workerIndex+1)*$descriptor.OutputChannels/[double]$workerCount)
        $referenceWorkers.Add($referenceWorker)
        $referenceTasks.Add([Threading.Tasks.Task]::Run($workerType.GetMethod('Run').CreateDelegate([Action],$referenceWorker)))
    }
    [Threading.Tasks.Task]::WaitAll($referenceTasks.ToArray())
    return ,$outputValues
}
function Get-TemplateNorm([string]$Name) {
    $weight = [float[]]::new($channels); [Array]::Fill($weight,[float]1)
    $bias = [float[]]::new($channels)
    if ($checkpoint.Tensors.Contains($Name+'.norm.weight')) { $weight=Read-TemplateWeight ($Name+'.norm.weight') }
    if ($checkpoint.Tensors.Contains($Name+'.norm.bias')) { $bias=Read-TemplateWeight ($Name+'.norm.bias') }
    [pscustomobject]@{Weight=$weight;Bias=$bias;Fc=(Read-TemplateWeight ($Name+'.fc.weight'));FcBias=(Read-TemplateWeight ($Name+'.fc.bias'))}
}
$prefix = "decoder.module.generator.resblocks.$ResBlockIndex"
$branchInput = $sharedInput
for ($previous=0; $previous -lt $DilationIndex; $previous++) {
    $norm = Get-TemplateNorm ($prefix+".adain1.$previous")
    $values = $adaIn.Invoke($branchInput,$channels,$frames,$style,$norm.Fc,$norm.FcBias,$norm.Weight,$norm.Bias)
    $values = $snake.Invoke($values,(Read-TemplateWeight ($prefix+".alpha1.$previous")),$frames)
    $values = Invoke-TemplateReferenceConvolution $values ($prefix+".convs1.$previous") (1+2*$previous)
    $norm = Get-TemplateNorm ($prefix+".adain2.$previous")
    $values = $adaIn.Invoke($values,$channels,$frames,$style,$norm.Fc,$norm.FcBias,$norm.Weight,$norm.Bias)
    $values = $snake.Invoke($values,(Read-TemplateWeight ($prefix+".alpha2.$previous")),$frames)
    $values = Invoke-TemplateReferenceConvolution $values ($prefix+".convs2.$previous")
    $branchInput = $residual.Invoke($values,$branchInput,[float]1)
}
$firstNorm = Get-TemplateNorm ($prefix+".adain1.$DilationIndex")
$activationInput = $adaIn.Invoke($branchInput,$channels,$frames,$style,$firstNorm.Fc,$firstNorm.FcBias,$firstNorm.Weight,$firstNorm.Bias)
$activationInput = $snake.Invoke($activationInput,(Read-TemplateWeight ($prefix+".alpha1.$DilationIndex")),$frames)
$weights = $fold.Invoke((Read-TemplateWeight ($prefix+".convs1.$DilationIndex.weight_v")),(Read-TemplateWeight ($prefix+".convs1.$DilationIndex.weight_g")))
$bias = Read-TemplateWeight ($prefix+".convs1.$DilationIndex.bias")
$reference = [float[]]::new($channels*$frames)
$indices = $indicesKernel.Invoke($frames,$frames,$kernelSize,1,$tapDilation,[int](($kernelSize-1)*$tapDilation/2),$false)
$vectors = $vectorKernel.Invoke($activationInput,$indices,$channels,$frames,$frames,$kernelSize)
$active = $activeKernel.Invoke($indices,$kernelSize)
$workers = [Collections.Generic.List[object]]::new(); $tasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
for ($thread=0; $thread -lt 4; $thread++) {
    $worker = [Activator]::CreateInstance($workerType)
    $worker.Input=$activationInput; $worker.Output=$reference; $worker.Weights=$weights; $worker.Bias=$bias
    $worker.Indices=$indices; $worker.VectorInput=$vectors; $worker.ActiveTaps=$active
    $worker.InputChannels=$channels; $worker.OutputChannels=$channels; $worker.InputFrames=$frames; $worker.OutputFrames=$frames
    $worker.Kernel=$kernelSize; $worker.Stride=1; $worker.Dilation=$tapDilation; $worker.Padding=[int](($kernelSize-1)*$tapDilation/2); $worker.Groups=1; $worker.Transpose=$false
    $worker.FirstChannel=($channels/4)*$thread; $worker.LastChannel=($channels/4)*($thread+1)
    $workers.Add($worker); $tasks.Add([Threading.Tasks.Task]::Run($workerType.GetMethod('Run').CreateDelegate([Action],$worker)))
}
[Threading.Tasks.Task]::WaitAll($tasks.ToArray())
$nextNorm = Get-TemplateNorm ($prefix+".adain2.$DilationIndex")
$alpha = Read-TemplateWeight ($prefix+".alpha2.$DilationIndex")
$statistics = $measureLevels.Invoke($reference,$channels,$frames,[int[]]@($frames))
$expectedOperand = $applyLevels.Invoke($reference,$channels,$frames,$style,$nextNorm.Fc,$nextNorm.FcBias,$nextNorm.Weight,$nextNorm.Bias,$statistics)
$affineInput = $expectedOperand
$expectedOperand = $snake.Invoke($expectedOperand,$alpha,$frames)
$coefficients = [float[]]::new(5*$channels)
(Get-GeneratorCoefficientsKernel).Invoke($style,$nextNorm.Fc,$nextNorm.FcBias,$nextNorm.Weight,$nextNorm.Bias,$statistics,$alpha,$coefficients)
if ($PhaseLock) {
    Import-Module (Join-Path $PSScriptRoot 'Kokoro.GeneratorLock.psm1')
    $lockTables = New-KokoroGeneratorLockTables -InputValues $affineInput -Alpha $alpha -AffineCoefficients $coefficients -Frames $frames -OutputFrames (32*$Tiles) -BlockFrames $BlockFrames
    $coefficients = $lockTables.NativeCoefficients
    Write-TemplateBinary 'lock-seats.f64' $lockTables.Seats
    [pscustomobject]@{Channels=$lockTables.Channels;Positions=$lockTables.Positions;BlockFrames=$lockTables.BlockFrames;
        Blocks=$lockTables.Blocks;StrideBytes=$lockTables.StrideBytes;SeatFields=[string[]]@('Mean','FoldedPhase','SinSquared','Slope','Direction');
        ProbeSHA256='84E9927E98E94AC619A30F9C553988774730F045B5530D65F74671B7265F6576'} |
        Export-Clixml -LiteralPath (Join-Path $output 'lock-description.clixml')
}
$emissionParameters = @{ConvChannels=$channels;ConvKernel=$kernelSize;ConvDilation=$tapDilation;ConvTiles=$Tiles;TemplateShape=$Shape;TemplateBlockFrames=$BlockFrames}
$encodingCheck = Test-KokoroKernel -Kernel KokoroGeneratorTemplate1Run -Parameters $emissionParameters
if (-not $encodingCheck.AssemblerMatch) { throw 'Template-1 SDK byte verification failed; device run rejected.' }
$emission = Invoke-KokoroEmission -Kernel KokoroGeneratorTemplate1Run -Parameters $emissionParameters
if ($emission.LibrarySHA256 -cne $encodingCheck.LibrarySHA256) { throw 'Phone candidate differs from the SDK-verified artifact.' }
$layout = $emission.Layout; $validFrames = 32*$Tiles
$packed = [ushort[]]::new($layout.ActivationBytes/2)
$inputSlice = Copy-TemplateFrames $activationInput $frames ($validFrames+32)
(Get-Fp16CroutonsKernel).Invoke($inputSlice,$validFrames+32,$channels,32,$packed)
$operandHalo = [ushort[]]::new($packed.Length)
$operandInputSlice = Copy-TemplateFrames $expectedOperand $frames ($validFrames+32)
(Get-Fp16CroutonsKernel).Invoke($operandInputSlice,$validFrames+32,$channels,32,$operandHalo)
$inputCroutons = [ushort[]]::new(2*$packed.Length)
[Array]::Copy($packed,0,$inputCroutons,0,$packed.Length)
[Array]::Copy($operandHalo,0,$inputCroutons,$packed.Length,$operandHalo.Length)
Write-TemplateBinary 'activations.bin' $inputCroutons
$nativeWeights = [ushort[]]::new($weights.Length)
(Get-PackFp16WeightsKernel).Invoke($weights,$channels,$channels,$kernelSize,$nativeWeights)
$identity = [float[]]::new($kernelSize*$channels*$channels)
$identityParameter = [Expression]::Parameter([float[]],'identity')
$identityStores = [Collections.Generic.List[Expression]]::new()
for ($channel=0; $channel -lt $channels; $channel++) {
    $identityStores.Add([Expression]::Assign([Expression]::ArrayAccess($identityParameter,[Expression]::Constant([int](($channel*$channels+$channel)*$kernelSize+($kernelSize-1)/2))),[Expression]::Constant([float]1)))
}
[Expression]::Lambda([Action[float[]]],[Expression]::Block($identityStores),[ParameterExpression[]]@($identityParameter)).Compile().Invoke($identity)
$identityWeights = [ushort[]]::new($identity.Length)
(Get-PackFp16WeightsKernel).Invoke($identity,$channels,$channels,$kernelSize,$identityWeights)
if ($ConnectedConsumer) {
    $consumerWeights = $fold.Invoke((Read-TemplateWeight ($prefix+".convs2.$DilationIndex.weight_v")),(Read-TemplateWeight ($prefix+".convs2.$DilationIndex.weight_g")))
    (Get-PackFp16WeightsKernel).Invoke($consumerWeights,$channels,$channels,$kernelSize,$identityWeights)
}
$allWeights = [ushort[]]::new($nativeWeights.Length+$identityWeights.Length)
[Array]::Copy($nativeWeights,0,$allWeights,0,$nativeWeights.Length); [Array]::Copy($identityWeights,0,$allWeights,$nativeWeights.Length,$identityWeights.Length)
Write-TemplateBinary 'weights.bin' $allWeights
$conversion = [uint[]]::new($layout.ConversionBytes/4); $identityConversion = [uint[]]::new($conversion.Length)
(Get-Fp16ConversionTableKernel).Invoke($bias,$conversion)
(Get-Fp16ConversionTableKernel).Invoke([float[]]::new($channels),$identityConversion)
if ($ConnectedConsumer) {
    (Get-Fp16ConversionTableKernel).Invoke((Read-TemplateWeight ($prefix+".convs2.$DilationIndex.bias")),$identityConversion)
}
$tables = [byte[]]::new($layout.TableBytes)
[Buffer]::BlockCopy($conversion,0,$tables,0,$layout.ConversionBytes)
[Buffer]::BlockCopy($coefficients,0,$tables,$layout.ConversionBytes,4*$coefficients.Length)
[Buffer]::BlockCopy($identityConversion,0,$tables,$layout.ConversionBytes+$layout.EpilogueBytes,$layout.ConversionBytes)
[IO.File]::WriteAllBytes((Join-Path $output 'tables.bin'),$tables)
$result = Invoke-KokoroDeviceJob -EmissionDirectory $emission.Directory -EmissionArtifact $emission -InputDirectory $output -Soc $Soc -Runs $Runs -Package $Package
$decoded = [Collections.Generic.List[float[]]]::new()
for ($part=0; $part -lt 3; $part++) {
    $native = [ushort[]]::new($layout.ResultBytes/2)
    [Buffer]::BlockCopy($result.Output,256+$part*$layout.ResultBytes,$native,0,$layout.ResultBytes)
    $values = [float[]]::new($channels*$validFrames)
    (Get-Fp16CroutonsKernel -Direction Decode).Invoke($values,$validFrames,$channels,0,$native)
    Write-TemplateBinary ("part$part.f32") $values
    if ([Array]::Exists[float]($values,$nonfinite)) { throw "STOP: NaN/Inf in template-1 output part $part; native output retained under $output" }
    $decoded.Add($values)
}
$referenceSlice = Copy-TemplateFrames $reference $frames $validFrames
$operandSlice = Copy-TemplateFrames $expectedOperand $frames $validFrames
Write-TemplateBinary 'reference-convolution.f32' $referenceSlice
Write-TemplateBinary 'reference-operand.f32' $operandSlice
$actualInputSlice = [float[]]::new($channels*($validFrames+32))
(Get-Fp16CroutonsKernel -Direction Decode).Invoke($actualInputSlice,$validFrames+32,$channels,32,$packed)
$actualInput = [float[]]$activationInput.Clone()
$actualOperand = [float[]]$expectedOperand.Clone()
$actualHaloSlice = [float[]]::new($actualInputSlice.Length)
(Get-Fp16CroutonsKernel -Direction Decode).Invoke($actualHaloSlice,$validFrames+32,$channels,32,$operandHalo)
$actualConvolution = [float[]]$reference.Clone()
for ($channel=0; $channel -lt $channels; $channel++) {
    [Array]::Copy($actualInputSlice,$channel*($validFrames+32),$actualInput,$channel*$frames,$validFrames+32)
    [Array]::Copy($actualHaloSlice,$channel*($validFrames+32),$actualOperand,$channel*$frames,$validFrames+32)
    [Array]::Copy($decoded[1],$channel*$validFrames,$actualOperand,$channel*$frames,$validFrames)
    [Array]::Copy($decoded[0],$channel*$validFrames,$actualConvolution,$channel*$frames,$validFrames)
}
$ownConvolutionReference = Copy-TemplateFrames (Invoke-TemplateReferenceConvolution $actualInput ($prefix+".convs1.$DilationIndex") $tapDilation) $frames $validFrames
$ownOperandReference = $applyLevels.Invoke($actualConvolution,$channels,$frames,$style,$nextNorm.Fc,$nextNorm.FcBias,$nextNorm.Weight,$nextNorm.Bias,$statistics)
if ($PhaseLock) {
    $shapeReference = Invoke-KokoroGeneratorLockReference -InputValues $ownOperandReference -Alpha $alpha -Tables $lockTables -Frames $frames -OutputFrames $validFrames
    $shapeMetrics = $compare.Invoke($decoded[1],$shapeReference)
    Write-TemplateBinary 'reference-own-input-lock.f32' $shapeReference
}
$ownOperandReference = Copy-TemplateFrames ($snake.Invoke($ownOperandReference,$alpha,$frames)) $frames $validFrames
$convolutionMetrics = $compare.Invoke($decoded[0],$ownConvolutionReference)
$operandMetrics = $compare.Invoke($decoded[1],$ownOperandReference)
Write-TemplateBinary 'reference-own-input-convolution.f32' $ownConvolutionReference
Write-TemplateBinary 'reference-own-input-operand.f32' $ownOperandReference
[float[]]$consumerReference = if ($ConnectedConsumer) {
    Copy-TemplateFrames (Invoke-TemplateReferenceConvolution $actualOperand ($prefix+".convs2.$DilationIndex")) $frames $validFrames
} else { $decoded[1] }
$consumerMetrics = $compare.Invoke($decoded[2],$consumerReference)
Write-TemplateBinary 'reference-consumer.f32' $consumerReference
$wavePaths = [Collections.Generic.List[string]]::new()
$pcmMetrics = @($null,$null); $stockPcmMetrics = @($null,$null)
if ($generatorStage -eq 1) {
# Listening evidence for this layer uses the verified offline continuation. Only this
# block's tested operand is replaced; this is not a claim of a whole-generator phone run.
$continuedOperand = [float[]]$expectedOperand.Clone()
for ($channel=0; $channel -lt $channels; $channel++) {
    [Array]::Copy($decoded[1],$channel*$validFrames,$continuedOperand,$channel*$frames,$validFrames)
}
function Invoke-TemplateReferenceContinuation([float[]]$OperandValues,[float[]]$ConsumerValues) {
$secondValues = Invoke-TemplateReferenceConvolution $OperandValues ($prefix+".convs2.$DilationIndex")
if ($null -ne $ConsumerValues) {
    for ($channel=0; $channel -lt $channels; $channel++) {
        [Array]::Copy($ConsumerValues,$channel*$validFrames,$secondValues,$channel*$frames,$validFrames)
    }
}
$continuedBranch = $residual.Invoke($secondValues,$branchInput,[float]1)
for ($stage=$DilationIndex+1; $stage -lt 3; $stage++) {
    $norm = Get-TemplateNorm ($prefix+".adain1.$stage")
    $nextValues = $adaIn.Invoke($continuedBranch,$channels,$frames,$style,$norm.Fc,$norm.FcBias,$norm.Weight,$norm.Bias)
    $nextValues = $snake.Invoke($nextValues,(Read-TemplateWeight ($prefix+".alpha1.$stage")),$frames)
    $nextValues = Invoke-TemplateReferenceConvolution $nextValues ($prefix+".convs1.$stage") (1+2*$stage)
    $norm = Get-TemplateNorm ($prefix+".adain2.$stage")
    $nextValues = $adaIn.Invoke($nextValues,$channels,$frames,$style,$norm.Fc,$norm.FcBias,$norm.Weight,$norm.Bias)
    $nextValues = $snake.Invoke($nextValues,(Read-TemplateWeight ($prefix+".alpha2.$stage")),$frames)
    $nextValues = Invoke-TemplateReferenceConvolution $nextValues ($prefix+".convs2.$stage")
    $continuedBranch = $residual.Invoke($nextValues,$continuedBranch,[float]1)
}
$branches = [object[]]::new(3)
for ($branch=0; $branch -lt 3; $branch++) {
    $index = 3+$branch
    $branches[$branch] = if ($index -eq $ResBlockIndex) { $continuedBranch } else {
        Read-TemplateFloatTensor (@($nodes.Nodes | Where-Object Name -CEQ "gen.resblocks$index")[0]) $nodeDirectory
    }
}
$average = $math.GetMethod('Average3').CreateDelegate([Func[float[],float[],float[],float[]]])
$leaky = $math.GetMethod('Leaky').CreateDelegate([Func[float[],float,float[]]])
$inverse = $math.GetMethod('InverseStft').CreateDelegate([Func[float[],int,float[]]])
$continued = $leaky.Invoke($average.Invoke($branches[0],$branches[1],$branches[2]),[float]0.01)
$continued = Invoke-TemplateReferenceConvolution $continued 'decoder.module.generator.conv_post'
return ,$inverse.Invoke($continued,$frames)
}
$baselinePcm = Invoke-TemplateReferenceContinuation $expectedOperand
$candidatePcm = if ($ConnectedConsumer) { Invoke-TemplateReferenceContinuation $continuedOperand $decoded[2] } else { Invoke-TemplateReferenceContinuation $continuedOperand }
Write-TemplateBinary 'reference-continuation-pcm.f32' $baselinePcm
Write-TemplateBinary 'candidate-continuation-pcm.f32' $candidatePcm
$stockPcm = Read-TemplateFloatTensor (@($dog.Tensors | Where-Object Name -CEQ 'pcm')[0]) $captureDirectory
$pcmMetrics = $compare.Invoke($candidatePcm,$baselinePcm)
$stockPcmMetrics = $compare.Invoke($candidatePcm,$stockPcm)
if ([Array]::Exists[float]($candidatePcm,$nonfinite)) { throw 'STOP: NaN/Inf in diagnostic continuation PCM.' }

# Reuse the compiled PCM writer from the requested MeasureAudio commit 93a6d82.
$audioRoot = 'C:\Users\Scott\.codex\worktrees\measure-audio\Kokoro-Hexagon'
$audioRelative = 'tools/Kokoro.AudioMeasurement.psm1'
$audioPath = Join-Path $audioRoot $audioRelative
$pinnedAudioBlob = git -C $audioRoot rev-parse "93a6d82:$audioRelative"
$actualAudioBlob = git -C $audioRoot hash-object -- $audioPath
if ($LASTEXITCODE -ne 0 -or $actualAudioBlob -cne $pinnedAudioBlob) { throw 'MeasureAudio source differs from commit 93a6d82.' }
$audioModule = Import-Module $audioPath -PassThru
$audioKernels = $audioModule.Invoke({Get-KokoroAudioKernels})[0]
$sampleArgument = [Expression]::Parameter([float],'sample')
$toDouble = [Expression]::Lambda([Converter[float,double]],[Expression]::Convert($sampleArgument,[double]),[ParameterExpression[]]@($sampleArgument)).Compile()
$stockAudio = [Array]::ConvertAll[float,double]($stockPcm,$toDouble)
$candidateAudio = [Array]::ConvertAll[float,double]($candidatePcm,$toDouble)
$pair = [double[]]::new($stockAudio.Length+14400+$candidateAudio.Length)
[Array]::Copy($stockAudio,0,$pair,0,$stockAudio.Length)
[Array]::Copy($candidateAudio,0,$pair,$stockAudio.Length+14400,$candidateAudio.Length)
foreach ($audioCase in @(@('stock.wav',$stockAudio),@('candidate-continuation.wav',$candidateAudio),@('stock-then-template1.wav',$pair))) {
    $wavePath = Join-Path $output $audioCase[0]
    $stream = [IO.File]::Create($wavePath); $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int](36+2*$audioCase[1].Length))
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
        $writer.Write([short]1); $writer.Write([short]1); $writer.Write([int]24000); $writer.Write([int]48000)
        $writer.Write([short]2); $writer.Write([short]16); $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([int](2*$audioCase[1].Length)); $audioKernels.Write.Invoke($writer,[double[]]$audioCase[1],1)
    } finally { $writer.Dispose(); $stream.Dispose() }
    $wavePaths.Add($wavePath)
}
$loudness = @(Measure-KokoroAudio -Path $output | Where-Object Path -In $wavePaths.GetRange(0,2))
$loudness | Export-Clixml -LiteralPath (Join-Path $output 'loudness.clixml')
}
$ticks = [BitConverter]::ToUInt64($result.Output,56)-[BitConverter]::ToUInt64($result.Output,48)
$milliseconds = [double]$ticks/19200.0
$macs = [long]$validFrames*$channels*$channels*$kernelSize
$receipt = [pscustomobject]@{Case='dog';Layer="generator.resblocks.$ResBlockIndex.convs1.$DilationIndex";Frames=$validFrames;Channels=$channels;Kernel=$kernelSize;Dilation=$tapDilation;
    ConvolutionSnrDb=$convolutionMetrics[0];ConvolutionMaxError=$convolutionMetrics[1];
    OperandSnrDb=$operandMetrics[0];OperandMaxError=$operandMetrics[1];
    ConsumerSnrDb=$consumerMetrics[0];ConsumerMaxError=$consumerMetrics[1];ConsumerExact=($consumerMetrics[1] -eq 0);
    ConnectedConsumer=[bool]$ConnectedConsumer;ConsumerLayer=$(if ($ConnectedConsumer) { "generator.resblocks.$ResBlockIndex.convs2.$DilationIndex" } else { 'identity' });
    SnakeShape=$Shape;BlockFrames=$BlockFrames;
    LockReferenceSnrDb=$(if ($PhaseLock) { $shapeMetrics[0] } else { $null });LockReferenceMaxError=$(if ($PhaseLock) { $shapeMetrics[1] } else { $null });
    LayerReferenceScope='Each operation reference consumes its own device input, including supplied FP16 halos';
    PcmSnrDb=$pcmMetrics[0];PcmMaxError=$pcmMetrics[1];StockPcmSnrDb=$stockPcmMetrics[0];StockPcmMaxError=$stockPcmMetrics[1];
    ListeningScope=$(if ($generatorStage -eq 1) { 'One tested layer block, identical verified offline continuation on both sides' } else { 'Stage A layer diagnostic; no PCM continuation' });WavePaths=$wavePaths.ToArray();
    HmxConvolutionMs=$milliseconds;HmxTmacPerSecond=([double]$macs/($milliseconds*1e9));
    HmxTimingScope='Run 0 convolution timer only; excludes DMA, epilogue and consumer; not a warm median';
    JobMedianMs=$result.MedianMs;JobTimingScope='Median over requested invocations, including run 0';Runs=$Runs;
    ReferenceAssemblySHA256=$referenceHash;ReferenceSourceSHA256=$sourceHash;LibrarySHA256=$emission.LibrarySHA256;
    ConstantsScope='Offline supplied levels for this layer diagnostic; not deployment calibration';
    InputDirectory=$output;CodeBytes=$emission.CodeBytes;VtcmBytes=$layout.VtcmBytes}
$receipt | Export-Clixml -LiteralPath (Join-Path $output 'gate.clixml')
$receipt
# A partial diagnostic continuation is not a whole-pipeline PCM admission gate.
# Whole-pipeline Supplied PCM below 25 dB and any NaN/Inf are the only numerical stops.
