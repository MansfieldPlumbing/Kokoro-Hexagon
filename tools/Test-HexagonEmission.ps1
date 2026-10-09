#requires -Version 7.4
# The SDK assembler is an independent verifier, never an input to the emitted ELF.
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\build\hexagon-emission\emitted'),
    [string] $ToolRoot = '/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/bin',
    [ValidateSet('Probe','KokoroAffine','KokoroAdaIn','KokoroAdaInResBlock','KokoroAdaInStatistics','KokoroAdaInIntegerCoefficients','KokoroAdaInIntegerAffine','KokoroSnakeInteger','KokoroResidualInteger','KokoroAlbertSoftmax3','KokoroAlbertAttention3','KokoroAlbertAttentionOutput3','KokoroAlbertConnectedAttention3','KokoroConvTile','KokoroLinearTile','KokoroR0Sub0','KokoroHmxLock','KokoroHmxMatrix','KokoroHmxConv','KokoroHmxConvPlanes','KokoroHmxConvPlanesLoop','KokoroPlaneCombine','KokoroPlaneCombineLoop','KokoroAdaInMoments16','KokoroAdaInMoments16Loop','KokoroAdaInTurnsCoefficients','KokoroAdaInAffineCoefficientsLoop','KokoroAdaInLeaky16','KokoroDecoderPass','KokoroHmxConvRun','KokoroResBlockRun','KokoroBranchAverageInteger','KokoroGenerator60xRun','KokoroLeakyReluInteger','KokoroVtcmQuery','KokoroDmaCopy','KokoroDmaBench','KokoroAdaInSnakeInteger','KokoroAdaInSnakeTurns','KokoroGenerator60xResidentRun','KokoroGenerator60x16Run','KokoroGeneratorTailRun','KokoroGeneratorTail16Run','KokoroGeneratorStage16TailRun','KokoroResBlock16Run','KokoroGeneratorFrontStageTailRun','KokoroGeneratorFront10x16Run','KokoroGeneratorWhole16Run','KokoroHarmonicStft16Run','KokoroHarmonicSource16Run','KokoroGeneratorWholeSource16Run')][string] $Kernel='Probe',
    [ValidateRange(2, 32768)][int] $ResBlockFrames = 7801,
    [ValidateSet(3,7,11)][int] $ResBlockKernel = 3,
    [ValidateSet(128,256)][int] $IntegerChannels = 128,
    [ValidateRange(1, 64)][int] $ConvTiles = 8,
    [ValidateSet(128, 256)][int] $ConvChannels = 128,
    [ValidateSet(1, 3, 7, 11)][int] $ConvKernel = 3,
    [ValidateRange(32, 2048)][int] $ConvInputChannels = 1120,
    [ValidateRange(64, 2048)][int] $ConvOutputChannels = 1024,
    [ValidateSet('Windows','Tensor')][string] $LeakyOutput = 'Windows',
    # KokoroDecoderPass: one pass of src/emit/Kokoro.Decoder16.ps1.
    [ValidateSet('PadRows16','LowWindow16','FrameDouble16','Pool2','StrideConv16')][string] $DecoderPass = 'PadRows16',
    [ValidateRange(1, 1048576)][int] $DecoderFrames = 65,
    [ValidateSet(0, 0x8000)][int] $DecoderHalfword = 0x8000,
    [ValidateRange(0, 2047)][int] $DecoderChannel = 1088,
    [ValidateRange(0, 1048576)][long] $CombineOutputTileSkip = 0,
    [ValidateSet(1, 3, 5)][int] $ConvDilation = 1,
    [switch] $ConvOutputPlanes,
    [ValidateSet(1,2)][int] $ConvWeightPlanes = 1,
    [ValidateSet('Conv','Residual','Scale')][string] $CombineMode = 'Conv',
    [ValidateSet(2,3)][int] $CombineGroups = 2,
    [ValidateRange(0,3)][int] $ResidentCostProbePasses = 0,
    [switch] $ResidentCostProbeTurnsBody,
    [ValidateCount(8,8)][ValidateRange(0,1023)][int[]] $ResidentPmuEvents,
    [ValidateRange(1,4)][int] $ResidentHvxThreads = 4,
    [ValidateRange(1,64)][int] $ResidentBatchTiles = 22,
    [switch] $ResidentCompactOutput,
    [ValidateRange(-1,17)][int] $Stage16StopAfter = -1,
    [ValidateCount(1,3)][int[]] $Stage16Kernels = @(3,7,11),
    [ValidateSet(128,256)][int] $Stage16Channels = 128,
    [ValidateRange(2, 2048)][int] $AdaInFrames = 64,
    [ValidateRange(1, 128)][int] $AdaInChannels = 128,
    [switch] $AdaInVectorConvolution,
    [ValidateRange(1, 512)][int] $LinearRows = 3,
    [ValidateRange(1, 4096)][int] $LinearInputChannels = 768,
    [ValidateRange(1, 4096)][int] $LinearOutputChannels = 512,
    [switch] $LinearVectorOutputTiles,
    [switch] $RegionBody,
    [switch] $ProfileBreakdown,
    [switch] $BypassAdaInCoefficients,
    [switch] $BypassStatisticsAndCoefficients,
    [switch] $BypassHmxCompute,
    [switch] $Force
)
$ErrorActionPreference='Stop'
$output=[IO.Path]::GetFullPath((Join-Path $OutputDirectory $Kernel))
$pmuArgs=if($ResidentPmuEvents){@{ResidentPmuEvents=$ResidentPmuEvents}}else{@{}}
$result=& (Join-Path $PSScriptRoot 'Emit-HexagonProbe.ps1') -OutputDirectory $output `
    -Kernel $Kernel -ResBlockFrames $ResBlockFrames -ResBlockKernel $ResBlockKernel -IntegerChannels $IntegerChannels -LinearRows $LinearRows -LinearInputChannels $LinearInputChannels `
    -LinearOutputChannels $LinearOutputChannels -LinearVectorOutputTiles:$LinearVectorOutputTiles `
    -AdaInFrames $AdaInFrames -AdaInChannels $AdaInChannels -AdaInVectorConvolution:$AdaInVectorConvolution -ConvChannels $ConvChannels -ConvInputChannels $ConvInputChannels -ConvOutputChannels $ConvOutputChannels -LeakyOutput $LeakyOutput -DecoderPass $DecoderPass -DecoderFrames $DecoderFrames -DecoderHalfword $DecoderHalfword -DecoderChannel $DecoderChannel -CombineOutputTileSkip $CombineOutputTileSkip -ConvKernel $ConvKernel -ConvDilation $ConvDilation -ConvOutputPlanes:$ConvOutputPlanes -ConvWeightPlanes $ConvWeightPlanes -CombineMode $CombineMode -CombineGroups $CombineGroups -ResidentCostProbePasses $ResidentCostProbePasses -ResidentCostProbeTurnsBody:$ResidentCostProbeTurnsBody -ConvTiles $ConvTiles -RegionBody:$RegionBody `
    -ProfileBreakdown:$ProfileBreakdown -BypassAdaInCoefficients:$BypassAdaInCoefficients -BypassStatisticsAndCoefficients:$BypassStatisticsAndCoefficients -BypassHmxCompute:$BypassHmxCompute -Force:$Force -ResidentHvxThreads $ResidentHvxThreads -ResidentBatchTiles $ResidentBatchTiles -ResidentCompactOutput:$ResidentCompactOutput -Stage16StopAfter $Stage16StopAfter -Stage16Kernels $Stage16Kernels -Stage16Channels $Stage16Channels @pmuArgs
$wslOutput=(& wsl.exe --exec wslpath -a $output 2>$null | Select-Object -Last 1).Trim()
if($LASTEXITCODE -ne 0 -or -not $wslOutput.StartsWith('/')) { throw 'Cannot resolve output directory in WSL' }
$assembler="$ToolRoot/hexagon-llvm-mc"
$hash=(& wsl.exe --exec sha256sum $assembler 2>$null | Select-Object -Last 1) -split '\s+'
if($LASTEXITCODE -ne 0 -or $hash[0] -ne 'fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27') { throw 'SDK assembler pin mismatch' }
# A fresh verification directory preserves previous reference artifacts.
$check=Join-Path $output ('check-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($check)
$wslCheck=(& wsl.exe --exec wslpath -a $check 2>$null | Select-Object -Last 1).Trim()
& wsl.exe --exec $assembler -triple=hexagon -mcpu=hexagonv73 "-mattr=+hvxv73,+hvx-length128b,+hvx-ieee-fp,+hmxv73" -filetype=obj "$wslOutput/probe-reference.s" -o "$wslCheck/reference.o" 2>$null
if($LASTEXITCODE -ne 0) { throw 'Independent assembly failed' }
# Read the ELF32 section table directly to extract .text, avoiding another tool dependency.
$object=[IO.File]::ReadAllBytes((Join-Path $check 'reference.o'))
if($object.Length -lt 52 -or [BitConverter]::ToUInt32($object,0) -ne 0x464C457F -or $object[4] -ne 1 -or $object[5] -ne 1) { throw 'Reference is not ELF32 little endian' }
$sectionOffset=[BitConverter]::ToUInt32($object,32)
$sectionSize=[BitConverter]::ToUInt16($object,46)
$sectionCount=[BitConverter]::ToUInt16($object,48)
$namesIndex=[BitConverter]::ToUInt16($object,50)
if($sectionSize -ne 40 -or $namesIndex -ge $sectionCount -or [long]$sectionOffset+[long]$sectionSize*$sectionCount -gt $object.Length) { throw 'Invalid reference section table' }
$nameSection=[long]$sectionOffset+$namesIndex*$sectionSize
$namesOffset=[BitConverter]::ToUInt32($object,$nameSection+16)
$namesSize=[BitConverter]::ToUInt32($object,$nameSection+20)
if([long]$namesOffset+$namesSize -gt $object.Length) { throw 'Invalid reference string table' }
$textBytes=$null
for($index=0;$index -lt $sectionCount;$index++) {
    $at=[long]$sectionOffset+$index*$sectionSize
    $nameAt=[long]$namesOffset+[BitConverter]::ToUInt32($object,$at)
    if($nameAt -ge [long]$namesOffset+$namesSize) { throw 'Invalid reference section name' }
    $end=$nameAt
    while($end -lt [long]$namesOffset+$namesSize -and $object[$end] -ne 0) { $end++ }
    if($end -ge [long]$namesOffset+$namesSize) { throw 'Unterminated reference section name' }
    $name=[Text.Encoding]::ASCII.GetString($object,$nameAt,$end-$nameAt)
    if($name -eq '.text') {
        if($null -ne $textBytes) { throw 'Duplicate reference text section' }
        $offset=[BitConverter]::ToUInt32($object,$at+16); $size=[BitConverter]::ToUInt32($object,$at+20)
        if([long]$offset+$size -gt $object.Length) { throw 'Invalid reference text section' }
        $textBytes=[byte[]]::new($size); [Array]::Copy($object,$offset,$textBytes,0,$size)
    }
}
if($null -eq $textBytes) { throw 'Reference text section absent' }
$emitted=[IO.File]::ReadAllBytes((Join-Path $output 'emitted-code.bin'))
if($emitted.Length -ne $textBytes.Length) { throw 'Reference code size mismatch' }
for($index=0;$index -lt $emitted.Length;$index++) {
    if($emitted[$index] -ne $textBytes[$index]) { throw "Reference instruction mismatch at byte $index" }
}
. (Join-Path $PSScriptRoot '..\src\emit\Hexagon.ps1')
$rejections=0
$badOps = @(
    @{Op='imm';d=32;i=1},
    @{Op='imm';d=0;i=32768},
    @{Op='load';d=0;s=1;Offset=3},
    @{Op='hi';x=0;i=65536},
    @{Op='vload';d=32;s=0;Offset=0},
    @{Op='vload';d=0;s=0;Offset=127},
    @{Op='vload';d=0;s=0;i=8},
    @{Op='vstore';t=32;s=0;Offset=0},
    @{Op='vadd-sf';d=32;s=0;t=0},
    @{Op='valign';d=32;s=0;t=0;r=0},
    @{Op='valign';d=0;s=0;t=0;r=8},
    @{Op='valign-imm';d=0;s=0;t=0;i=8},
        @{Op='trap0';i=256},
        @{Op='sfinvsqrta';d=0;s=1;e=4},
        @{Op='sfinvsqrta';d=32;s=1;e=0},
        @{Op='sfinvsqrta';d=0;s=32;e=0},
        @{Op='sfmax';d=32;s=1;t=2},
        @{Op='vmpy-sf-qf32';d=32;s=0;t=1},
        @{Op='vadd-sf-qf32';d=0;s=32;t=1},
        @{Op='vconv-qf32-sf';d=0;s=32}
)
foreach($bad in $badOps) {
    try { $null=New-HexagonInstruction $bad 0 0 } catch { $rejections++ }
}
if($rejections -ne $badOps.Count) { throw "Encoder accepted an invalid operand: got $rejections expected $($badOps.Count)" }
$summary=[ordered]@{LibrarySHA256=$result.SHA256;LibraryBytes=$result.Bytes;CodeBytes=$emitted.Length;AssemblerSHA256=$hash[0];InstructionBytesMatch=$true;InvalidOperandsRejected=$rejections;Imports=$result.Imports;Relocations=$result.Relocations;RegionBodyEncodingOnly=$result.RegionBodyEncodingOnly}
$summary | ConvertTo-Json | Set-Content (Join-Path $check 'verification.json')
[pscustomobject]$summary
