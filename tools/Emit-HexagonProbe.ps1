#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\build\hexagon-emission\emitted'),
    [ValidateSet('Probe','KokoroAffine','KokoroAdaIn','KokoroAdaInResBlock','KokoroAdaInStatistics','KokoroAdaInIntegerCoefficients','KokoroAdaInIntegerAffine','KokoroSnakeInteger','KokoroResidualInteger','KokoroAlbertSoftmax3','KokoroAlbertAttention3','KokoroAlbertAttentionOutput3','KokoroAlbertConnectedAttention3','KokoroConvTile','KokoroLinearTile','KokoroR0Sub0','KokoroHmxLock','KokoroHmxMatrix','KokoroHmxConv','KokoroHmxConvPlanes','KokoroHmxConvPlanesLoop','KokoroPlaneCombine','KokoroPlaneCombineLoop','KokoroAdaInMoments16','KokoroAdaInMoments16Loop','KokoroAdaInTurnsCoefficients','KokoroAdaInAffineCoefficientsLoop','KokoroAdaInLeaky16','KokoroDecoderPass','KokoroDecoder16Run','KokoroHmxConvRun','KokoroResBlockRun','KokoroBranchAverageInteger','KokoroGenerator60xRun','KokoroLeakyReluInteger','KokoroVtcmQuery','KokoroDmaCopy','KokoroDmaBench','KokoroAdaInSnakeInteger','KokoroAdaInSnakeTurns','KokoroGenerator60xResidentRun','KokoroGenerator60x16Run','KokoroGeneratorTailRun','KokoroGeneratorTail16Run','KokoroGeneratorStage16TailRun','KokoroResBlock16Run','KokoroGeneratorFrontStageTailRun','KokoroGeneratorFront10x16Run','KokoroGeneratorWhole16Run','KokoroHarmonicStft16Run','KokoroHarmonicSource16Run','KokoroGeneratorWholeSource16Run','KokoroDecoderGenerator16Run')][string] $Kernel='Probe',
    [ValidateRange(2, 32768)][int] $ResBlockFrames = 7801,
    [ValidateSet(3,7,11)][int] $ResBlockKernel = 3,
    [ValidateSet(128,256)][int] $IntegerChannels = 128,
    [ValidateRange(1, 64)][int] $ConvTiles = 8,
    [ValidateSet(128, 256)][int] $ConvChannels = 128,
    [ValidateSet(1, 3, 7, 11)][int] $ConvKernel = 3,
    # KokoroHmxConvPlanesLoop: decoder shapes (docs/decoder-design.md).
    [ValidateRange(32, 2048)][int] $ConvInputChannels = 1120,
    [ValidateRange(64, 2048)][int] $ConvOutputChannels = 1024,
    [ValidateSet('Windows','Tensor')][string] $LeakyOutput = 'Windows',
    [switch] $LeakyIdentity,
    # KokoroDecoderPass: one pass of src/kernels/Kokoro.Decoder16.ps1.
    [ValidateSet('PadRows16','LowWindow16','FrameDouble16','Pool2','StrideConv16','ScaleConvert16')][string] $DecoderPass = 'PadRows16',
    [ValidateRange(1, 1048576)][int] $DecoderFrames = 65,
    [ValidateSet(0, 0x8000)][int] $DecoderHalfword = 0x8000,
    [ValidateRange(0, 2047)][int] $DecoderChannel = 1088,
    [ValidateRange(0, 1048576)][long] $CombineOutputTileSkip = 0,
    [ValidateRange(-1, 4)][int] $DecoderStopAfterBlock = -1,
    [ValidateSet('Block','Shortcut','Conv1','Windows1','Pool','Coeff')][string] $DecoderDumpPoint = 'Block',
    # KokoroDecoder16Run: read the frame count at run time (DecoderFrames is the capacity).
    [switch] $DecoderRuntimeFrames,
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
    [switch] $TailDumpLogits,
    [ValidateCount(1,3)][int[]] $Stage16Kernels = @(3,7,11),
    [ValidateSet(128,256)][int] $Stage16Channels = 128,
    [ValidateSet('Stage','Windows','Planes')][string] $Stage16DumpPoint = 'Stage',
    [ValidateRange(2, 2048)][int] $AdaInFrames = 64,
    [ValidateRange(1, 128)][int] $AdaInChannels = 128,
    [switch] $AdaInVectorConvolution,
    [ValidateRange(1, 512)][int] $LinearRows = 3,
    [ValidateRange(1, 4096)][int] $LinearInputChannels = 768,
    [ValidateRange(1, 4096)][int] $LinearOutputChannels = 512,
    [switch] $LinearVectorOutputTiles,
    [switch] $RegionBody,
    [string] $WeightManifest = (Join-Path $PSScriptRoot '..\build\emit\r0\r0_static.json'),
    [switch] $ProfileBreakdown,
    [switch] $BypassAdaInCoefficients,
    [switch] $BypassStatisticsAndCoefficients,
    [switch] $BypassHmxCompute,
    [switch] $Force
)
$ErrorActionPreference = 'Stop'
if ($RegionBody -and $Kernel -notin @('KokoroAlbertAttention3','KokoroAlbertAttentionOutput3')) {
    throw 'Region-body encoding is supported only for the ALBERT attention regions.'
}
# Host-only. The pinned ELF writer uses .NET APIs requiring FullLanguage.
# Fetch source from an immutable upstream GitHub revision; never use or write
# the protected local Pwsh checkout. No model text is executed by this adapter.
$script:PwshBaseUrl = 'https://raw.githubusercontent.com/MansfieldPlumbing/Pwsh/e215a963295eda290599840366b51cbd99bb6d57/'
$protectedRoot = [IO.Path]::GetFullPath('C:\Dev\Pwsh').TrimEnd([IO.Path]::DirectorySeparatorChar)
$outputFullPath = [IO.Path]::GetFullPath($OutputDirectory)
if ($outputFullPath.Equals($protectedRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $outputFullPath.StartsWith($protectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must not be inside the protected Pwsh checkout.'
}
$OutputDirectory = $outputFullPath
function Get-PinnedUpstreamText {
    param(
        [Parameter(Mandatory)][ValidatePattern('^(setup\.ps1|lib/[A-Za-z0-9._-]+)$')][string] $Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string] $Sha256
    )
    $response = Invoke-WebRequest -Uri ($script:PwshBaseUrl + $Path) -UseBasicParsing
    $bytes = $response.RawContentStream.ToArray()
    $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($actual -cne $Sha256) { throw "Pinned upstream source hash mismatch: $Path" }
    [Text.Encoding]::UTF8.GetString($bytes)
}
$setupText = Get-PinnedUpstreamText 'setup.ps1' '44432CB738EDB13FB7B2AEA999C265A94F5EEAC867DC4E4E39C1503E0E813D62'
$manifestText = Get-PinnedUpstreamText 'lib/manifest.json' 'C2B3C6D044EACBACAD7E7B1C58F18EA8AE6FB836B421B5EC3788D009E57CEDC4'
$script:PwshSources = ($manifestText | ConvertFrom-Json).sources
function Import-LibSourceText {
    param([string] $Path)
    $record = @($script:PwshSources | Where-Object path -CEQ $Path)
    if ($record.Count -ne 1) { throw "Missing source pin: $Path" }
    Get-PinnedUpstreamText "lib/$Path" ([string]$record[0].sha256)
}
function Write-NewOrIdenticalFile {
    param([string] $Path, [byte[]] $Bytes, [switch] $AllowOverwrite)
    if ([IO.File]::Exists($Path)) {
        if (-not $AllowOverwrite -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))) -ne
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))) { throw "Output exists with different bytes: $Path. Choose a new output directory." }
        [IO.File]::WriteAllBytes($Path,$Bytes)
    } else { [IO.File]::WriteAllBytes($Path,$Bytes) }
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($setupText,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Pinned writer does not parse' }
$names=@('Get-ElfConstants','Get-ElfHashTableBytes','Get-ElfLayout','Get-ElfHeaderFlags',
    'Get-ElfRelocationEntrySize','Get-ElfRelocationTags','Get-AlignedOffset','Set-ElfField',
    'New-ElfStringTable','Write-ElfHeader','Write-ElfProgramHeader','Write-ElfSymbol',
    'Write-ElfDynamicTable','Write-ElfRelocation','Add-ElfSectionTable','New-ElfCodeLibrary')
$definitions=foreach($name in $names) {
    $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false))
    if($nodes.Count -ne 1) { throw "Writer function not unique: $name" }
    $source=$nodes[0].Extent.Text
    if($name -eq 'New-ElfCodeLibrary') {
        # Three explicit adaptations: permit zero imports, reserve one extra dynamic
        # entry, and write the ABI-mandatory DT_HEXAGON_VER=3 (SDK 19.0.04 ABI guide).
        $edits=@(
            @('[Parameter(Mandatory)][string[]] $Needed','[AllowEmptyCollection()][string[]] $Needed'),
            @('$L.Dynamic * (11 + $Needed.Count)','$L.Dynamic * (12 + $Needed.Count)'),
            @('@($elf[''DT_NULL''], 0)))','@($elf[''DT_HEXAGON_VER''], 3), @($elf[''DT_NULL''], 0)))')
        )
        foreach($edit in $edits) {
            if(([regex]::Matches($source,[regex]::Escape($edit[0]))).Count -ne 1) { throw 'Writer adaptation anchor mismatch' }
            $source=$source.Replace($edit[0],$edit[1])
        }
    }
    $source
}
$adapter=Join-Path $OutputDirectory 'Pwsh.ElfWriter.ps1'
$text=$definitions -join "`n`n"
$null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Writer adapter does not parse' }
Write-NewOrIdenticalFile $adapter ([Text.Encoding]::UTF8.GetBytes($text)) -AllowOverwrite:$Force
. $adapter
. (Join-Path $PSScriptRoot '..\src\hexagon\Hexagon.ps1')
$script:ElfConstants=$null
$elf=Get-ElfConstants
$header=Import-LibSourceText 'ELF.h'
foreach($name in 'EM_HEXAGON','EF_HEXAGON_ISA_V73') {
    $m=[regex]::Match($header,"\b$name\s*=\s*(0x[0-9a-fA-F]+|\d+)")
    if(-not $m.Success) { throw "Missing $name" }
    $elf[$name]=[Convert]::ToUInt32($m.Groups[1].Value.Replace('0x',''),$(if($m.Groups[1].Value.StartsWith('0x')){16}else{10}))
}
$m=[regex]::Match((Import-LibSourceText 'DynamicTags.def'),'HEXAGON_DYNAMIC_TAG\(HEXAGON_VER,\s*(0x[0-9a-fA-F]+)\)')
if(-not $m.Success) { throw 'Missing Hexagon dynamic version tag' }
$elf.DT_HEXAGON_VER=[Convert]::ToUInt32($m.Groups[1].Value.Substring(2),16)
# llvm-project 08169f5fb1b7386002cdb66e52192580fc0fcf24 llvm/include/llvm/BinaryFormat/ELFRelocs/Hexagon.def:40,42
$elf['R_HEX_GLOB_DAT']=[uint32]33; $elf['R_HEX_RELATIVE']=[uint32]35
$script:Target=[pscustomobject]@{ElfClass=32;Machine='EM_HEXAGON';ElfFlags=@('EF_HEXAGON_ISA_V73');RelocationForm='RELA';GotRelocation='R_HEX_GLOB_DAT';RelativeRelocation='R_HEX_RELATIVE'}
if($Kernel -eq 'KokoroR0Sub0') {
    $modelPath=Join-Path $PSScriptRoot '..\src\models\Kokoro.R0Sub0.ps1'
    $modelAst=[Management.Automation.Language.Parser]::ParseFile($modelPath,[ref]$tokens,[ref]$errors)
    if($errors.Count) { throw 'R0Sub0 model does not parse' }
    $nodes=@(& (Join-Path $PSScriptRoot '..\src\lower\Lower-Model.ps1') -Model $modelAst.GetScriptBlock())
    $weights=Get-Content $WeightManifest -Raw | ConvertFrom-Json
    $weightPath=Join-Path (Split-Path $WeightManifest) 'r0_static.bin'
    if((Get-FileHash $weightPath).Hash -ne $weights.Sha256 -or (Get-Item $weightPath).Length -ne $weights.Bytes) { throw 'Existing weights fail their manifest' }
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.R0Sub0.ps1')
    $steps=@(New-KokoroR0Sub0Steps -Nodes $nodes -Frames 7681 -Channels $weights.Channels -WeightBytes $weights.Bytes -Weights $weights.Values)
    $symbol='kokoro_r0sub0_skel_handle_invoke'; $soname='libkokoro_r0sub0_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'lowered.json') ([Text.Encoding]::UTF8.GetBytes(($nodes | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -in 'KokoroAffine','KokoroConvTile') {
    $modelName=if($Kernel -eq 'KokoroAffine'){'Kokoro.Affine.ps1'}else{'Kokoro.ConvTile.ps1'}
    $modelPath=Join-Path $PSScriptRoot "..\src\models\$modelName"
    $modelAst=[Management.Automation.Language.Parser]::ParseFile($modelPath,[ref]$tokens,[ref]$errors)
    if($errors.Count) { throw 'Model does not parse' }
    # GetScriptBlock supplies an AST to the lowerer; the model is never invoked.
    $nodes=@(& (Join-Path $PSScriptRoot '..\src\lower\Lower-Model.ps1') -Model $modelAst.GetScriptBlock())
    $weights=Get-Content $WeightManifest -Raw | ConvertFrom-Json
    $weightPath=Join-Path (Split-Path $WeightManifest) 'r0_static.bin'
    if((Get-FileHash $weightPath).Hash -ne $weights.Sha256 -or (Get-Item $weightPath).Length -ne $weights.Bytes) { throw 'Existing weights fail their manifest' }
    if($Kernel -eq 'KokoroAffine') {
        . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.Affine.ps1')
        $steps=@(New-KokoroAdaInAffineSteps -Nodes $nodes -Channels $weights.Channels -GainOffset $weights.Values.'adain1.0.gain'.Offset -ShiftOffset $weights.Values.'adain1.0.shift'.Offset -WeightBytes $weights.Bytes)
        $symbol='kqnn_affine_skel_handle_invoke'; $soname='libkqnn_affine_skel.so'
    } else {
        if(($weights.Values.'convs1.0.weight'.Shape -join ',') -ne '1,3,128,128' -or
            ($weights.Values.'convs1.0.bias'.Shape -join ',') -ne '128') { throw 'Unexpected convolution weight layout' }
        . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.ConvTile.ps1')
        $steps=@(New-KokoroConvTileSteps -Nodes $nodes -Channels $weights.Channels -WeightOffset $weights.Values.'convs1.0.weight'.Offset -BiasOffset $weights.Values.'convs1.0.bias'.Offset -WeightBytes $weights.Bytes)
        $symbol='kokoro_conv_skel_handle_invoke'; $soname='libkokoro_conv_skel.so'
    }
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'lowered.json') ([Text.Encoding]::UTF8.GetBytes(($nodes | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroAdaIn') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaIn.ps1')
    $steps=@(New-KokoroAdaInSteps -Frames $AdaInFrames -Channels $AdaInChannels)
    $symbol='kokoro_adain_skel_handle_invoke'; $soname='libkokoro_adain_skel.so'
} elseif($Kernel -eq 'KokoroAdaInResBlock') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaIn.ps1')
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaInResBlock.ps1')
    $steps=@(New-KokoroAdaInResBlockSteps -Frames $AdaInFrames -VectorConvolution:$AdaInVectorConvolution)
    $symbol='kokoro_adain_resblock_skel_handle_invoke'; $soname='libkokoro_adain_resblock_skel.so'
} elseif($Kernel -eq 'KokoroAlbertSoftmax3') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AlbertSoftmax3.ps1')
    $steps=@(New-KokoroAlbertSoftmax3Steps)
    $symbol='kokoro_albert_softmax3_skel_handle_invoke'; $soname='libkokoro_albert_softmax3_skel.so'
} elseif($Kernel -eq 'KokoroAlbertAttention3') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AlbertAttention3.ps1')
    $steps=if ($RegionBody) { @(New-KokoroAlbertAttention3Steps -RegionBody -LabelPrefix 'encoded_context' -DomainFailureLabel 'encoding_domain') } else { @(New-KokoroAlbertAttention3Steps) }
    $symbol='kokoro_albert_attention3_skel_handle_invoke'; $soname='libkokoro_albert_attention3_skel.so'
} elseif($Kernel -eq 'KokoroAlbertAttentionOutput3') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AlbertAttentionOutput3.ps1')
    $steps=if ($RegionBody) { @(New-KokoroAlbertAttentionOutput3Steps -RegionBody -LabelPrefix 'encoded_output' -DomainFailureLabel 'encoding_domain') } else { @(New-KokoroAlbertAttentionOutput3Steps) }
    $symbol='kokoro_albert_attention_output3_skel_handle_invoke'; $soname='libkokoro_albert_attention_output3_skel.so'
} elseif($Kernel -eq 'KokoroAlbertConnectedAttention3') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AlbertConnectedAttention3.ps1')
    $steps=@(New-KokoroAlbertConnectedAttention3Steps)
    $symbol='kokoro_albert_connected_attention3_skel_handle_invoke'; $soname='libkokoro_albert_connected_attention3_skel.so'
} elseif($Kernel -eq 'KokoroHmxLock') {
    . (Join-Path $PSScriptRoot '..\src\hexagon\Kokoro.HmxLockProbe.ps1')
    $steps=@(New-KokoroHmxLockSteps)
    $symbol='kokoro_hmx_lock_skel_handle_invoke'; $soname='libkokoro_hmx_lock_skel.so'
} elseif($Kernel -eq 'KokoroHmxMatrix') {
    . (Join-Path $PSScriptRoot '..\src\hexagon\Kokoro.HmxMatrixProbe.ps1')
    $steps=@(New-KokoroHmxMatrixSteps)
    $symbol='kokoro_hmx_matrix_skel_handle_invoke'; $soname='libkokoro_hmx_matrix_skel.so'
} elseif($Kernel -eq 'KokoroAdaInStatistics') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaInStatistics.ps1')
    $steps=@(New-KokoroAdaInStatisticsSteps -Channels $IntegerChannels)
    $symbol='kokoro_adain_statistics'; $soname='libkokoro_adain_statistics.so'
} elseif($Kernel -eq 'KokoroAdaInIntegerCoefficients') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaInInteger.ps1')
    $steps=@(New-KokoroAdaInIntegerCoefficientsSteps -Channels $IntegerChannels)
    $symbol='kokoro_adain_integer_coefficients'; $soname='libkokoro_adain_integer_coefficients.so'
} elseif($Kernel -eq 'KokoroAdaInIntegerAffine') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaInInteger.ps1')
    $steps=@(New-KokoroAdaInIntegerAffineSteps -Channels $IntegerChannels)
    $symbol='kokoro_adain_integer_affine'; $soname='libkokoro_adain_integer_affine.so'
} elseif($Kernel -eq 'KokoroAdaInSnakeInteger') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaInSnakeInteger.ps1')
    $steps=@(New-KokoroAdaInSnakeIntegerSteps)
    $symbol='kokoro_adain_snake_integer'; $soname='libkokoro_adain_snake_integer.so'
} elseif($Kernel -eq 'KokoroAdaInSnakeTurns') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.AdaInSnakeTurns.ps1')
    $steps=@(New-KokoroAdaInSnakeTurnsSteps)
    $symbol='kokoro_adain_snake_turns'; $soname='libkokoro_adain_snake_turns.so'
} elseif($Kernel -eq 'KokoroSnakeInteger') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.SnakeInteger.ps1')
    $steps=@(New-KokoroSnakeIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_snake_integer'; $soname='libkokoro_snake_integer.so'
} elseif($Kernel -eq 'KokoroResidualInteger') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.ResidualInteger.ps1')
    $steps=@(New-KokoroResidualIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_residual_integer'; $soname='libkokoro_residual_integer.so'
} elseif($Kernel -eq 'KokoroHmxConv') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.HmxConv.ps1')
    $steps=@(New-KokoroHmxConvSteps -InputChannels $ConvChannels -OutputChannels $ConvChannels -Kernel $ConvKernel -Dilation $ConvDilation -OutputPlanes:$ConvOutputPlanes)
    $symbol='kokoro_hmx_conv'; $soname='libkokoro_hmx_conv.so'
} elseif($Kernel -eq 'KokoroLeakyReluInteger') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.LeakyReluInteger.ps1')
    $steps=@(New-KokoroLeakyReluIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_leaky_relu_integer'; $soname='libkokoro_leaky_relu_integer.so'
} elseif($Kernel -eq 'KokoroBranchAverageInteger') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.BranchAverageInteger.ps1')
    $steps=@(New-KokoroBranchAverageIntegerSteps -Channels $IntegerChannels)
    $symbol='kokoro_branch_average_integer'; $soname='libkokoro_branch_average_integer.so'
} elseif($Kernel -eq 'KokoroGenerator60xRun') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60xRun.ps1')
    $run=New-KokoroGenerator60xRunSteps -Frames $ResBlockFrames -ProfileBreakdown:$ProfileBreakdown -BypassAdaInCoefficients:$BypassAdaInCoefficients -BypassStatisticsAndCoefficients:$BypassStatisticsAndCoefficients -BypassHmxCompute:$BypassHmxCompute
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorTailRun') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.GeneratorTailRun.ps1')
    $run=New-KokoroGeneratorTailRunSteps -Frames $ResBlockFrames
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorStage16TailRun') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Tail
    $steps=@($run.Steps)
    # The tail harness (src/runspace/KokoroGeneratorTailProbe.ps1) loads this name and plays the PCM.
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroResBlock16Run') {
    # One or more 16-bit resblocks without the tail, under the generic tail harness (completion word 1 for one block).
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Kernels $Stage16Kernels -Channels $Stage16Channels -GenericHarness -StopAfterStage $Stage16StopAfter -DumpPoint $Stage16DumpPoint
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorFrontStageTailRun') {
    # The 128-channel front, the 16-bit stage and the tail in one job (tail harness plays the PCM).
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Front -Tail
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorWholeSource16Run') {
    # The whole generator with the harmonic source: decoder output, f0 and z to PCM (tail harness plays the PCM) under the generic tail harness (completion word 1).
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Whole -Source
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroDecoderGenerator16Run') {
    # The decoder then the whole generator with the harmonic source: asr, F0_curve, N_curve, f0 and z to PCM, one DSP job.
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Whole -Source -Decoder
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroHarmonicSource16Run') {
    # The harmonic source and STFT (f0 -> har planes, signal copy) under the generic tail harness (completion word 1).
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.HarmonicSource16Run.ps1')
    $run=New-KokoroHarmonicSource16RunSteps -Frames $ResBlockFrames
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroHarmonicStft16Run') {
    # The harmonic-source STFT (merged source -> har planes) under the generic tail harness (completion word 1).
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.HarmonicStft16Run.ps1')
    $run=New-KokoroHarmonicStft16RunSteps -Frames $ResBlockFrames
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorWhole16Run') {
    # The whole generator in one job: decoder output and har to PCM (tail harness plays the PCM).
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Whole
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorFront10x16Run') {
    # The 256-channel front and resblocks.0-2 with their mean, under the generic tail harness.
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -Channels 256 -Front -GenericHarness
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroDecoder16Run') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.DecoderRun16.ps1')
    $run=New-KokoroDecoder16RunSteps -Frames $DecoderFrames -StopAfterBlock $DecoderStopAfterBlock -DumpPoint $DecoderDumpPoint -RuntimeFrames:$DecoderRuntimeFrames
    $steps=@($run.Steps)
    # The phone harness (tools/Invoke-GeneratorTailProbe.ps1) runs every generator job under the tail skel's name.
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGeneratorTail16Run') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.GeneratorTail16Run.ps1')
    $run=New-KokoroGeneratorTail16RunSteps -Frames $ResBlockFrames -DumpLogits:$TailDumpLogits
    $steps=@($run.Steps)
    $symbol='kokoro_generator_tail_skel_handle_invoke'; $soname='libkokoro_generator_tail_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGenerator60x16Run') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60x16Run.ps1')
    $pmu=if($ResidentPmuEvents){@{PmuEvents=$ResidentPmuEvents}}else{@{}}
    $run=New-KokoroGenerator60x16RunSteps -Frames $ResBlockFrames -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -StopAfterStage $Stage16StopAfter -DumpPoint $Stage16DumpPoint -Kernels $Stage16Kernels @pmu
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroGenerator60xResidentRun') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.Generator60xResidentRun.ps1')
    $pmu=if($ResidentPmuEvents){@{PmuEvents=$ResidentPmuEvents}}else{@{}}
    $run=New-KokoroGenerator60xResidentRunSteps -Frames $ResBlockFrames -CostProbePasses $ResidentCostProbePasses -CostProbeTurnsBody:$ResidentCostProbeTurnsBody -HvxThreads $ResidentHvxThreads -BatchTiles $ResidentBatchTiles -CompactOutput:$ResidentCompactOutput @pmu
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json -Depth 6))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroResBlockRun') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.ResBlockRun.ps1')
    $run=New-KokoroResBlockRunSteps -Frames $ResBlockFrames -Kernel $ResBlockKernel
    $steps=@($run.Steps)
    $symbol='kokoro_resblock_run_skel_handle_invoke'; $soname='libkokoro_resblock_run_skel.so'
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-layout.json') ([Text.Encoding]::UTF8.GetBytes(($run.Layout | ConvertTo-Json))) -AllowOverwrite:$Force
} elseif($Kernel -eq 'KokoroHmxConvPlanes') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.HmxConvPlanes.ps1')
    # Plane stride for the simulator harness: 3 output tiles of ConvChannels/32 blocks.
    $steps=@(New-KokoroHmxConvPlanesSteps -InputChannels $ConvChannels -OutputChannels $ConvChannels -Kernel $ConvKernel -Dilation $ConvDilation -WeightPlanes $ConvWeightPlanes -PlaneStride (3*($ConvChannels/32)*2048))
    $symbol='kokoro_hmx_conv_planes'; $soname='libkokoro_hmx_conv_planes.so'
} elseif($Kernel -eq 'KokoroHmxConvPlanesLoop') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.HmxConvPlanes.ps1')
    # Plane stride for the simulator harness: 3 output tiles of ConvOutputChannels/32 blocks.
    $steps=@(New-KokoroHmxConvPlanesLoopSteps -InputChannels $ConvInputChannels -OutputChannels $ConvOutputChannels -Kernel $ConvKernel -Dilation $ConvDilation -WeightPlanes $ConvWeightPlanes -PlaneStride (3*($ConvOutputChannels/32)*2048))
    $symbol='kokoro_hmx_conv_planes_loop'; $soname='libkokoro_hmx_conv_planes_loop.so'
} elseif($Kernel -eq 'KokoroPlaneCombine') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.PlaneCombine.ps1')
    $steps=@(New-KokoroPlaneCombineSteps -Mode $CombineMode -Channels $ConvChannels -Groups $CombineGroups -PlaneStride (3*($ConvChannels/32)*2048))
    $symbol='kokoro_plane_combine'; $soname='libkokoro_plane_combine.so'
} elseif($Kernel -eq 'KokoroPlaneCombineLoop') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.PlaneCombine.ps1')
    $steps=@(New-KokoroPlaneCombineLoopSteps -Mode $CombineMode -Channels $ConvOutputChannels -PlaneStride (3*($ConvOutputChannels/32)*2048) -OutputTileSkip $CombineOutputTileSkip)
    $symbol='kokoro_plane_combine_loop'; $soname='libkokoro_plane_combine_loop.so'
} elseif($Kernel -eq 'KokoroAdaInMoments16Loop') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.AdaInMoments16.ps1')
    $steps=@(New-KokoroAdaInMoments16LoopSteps -Channels $ConvInputChannels)
    $symbol='kokoro_adain_moments16_loop'; $soname='libkokoro_adain_moments16_loop.so'
} elseif($Kernel -eq 'KokoroAdaInMoments16') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.AdaInMoments16.ps1')
    $steps=@(New-KokoroAdaInMoments16Steps -Channels $ConvChannels)
    $symbol='kokoro_adain_moments16'; $soname='libkokoro_adain_moments16.so'
} elseif($Kernel -eq 'KokoroAdaInAffineCoefficientsLoop') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.AdaInTurnsCoefficients.ps1')
    $steps=@(New-KokoroAdaInAffineCoefficientsLoopSteps -Channels $ConvInputChannels)
    $symbol='kokoro_adain_affine_coefficients_loop'; $soname='libkokoro_adain_affine_coefficients_loop.so'
} elseif($Kernel -eq 'KokoroDecoderPass') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.Decoder16.ps1')
    $steps=@(switch($DecoderPass){
        'PadRows16' { New-KokoroPadRows16Steps -Frames $DecoderFrames -Channels $ConvInputChannels -Halfword $DecoderHalfword }
        'LowWindow16' { New-KokoroLowWindow16Steps }
        'FrameDouble16' { New-KokoroFrameDouble16Steps -Channels $ConvInputChannels }
        'Pool2' { New-KokoroPool2Steps -Channels $ConvInputChannels }
        'StrideConv16' { New-KokoroStrideConv16Steps -Frames $DecoderFrames -Channels $ConvInputChannels -Channel $DecoderChannel }
        'ScaleConvert16' { New-KokoroScaleConvert16Steps -Channels $ConvInputChannels } })
    $symbol='kokoro_decoder_pass'; $soname='libkokoro_decoder_pass.so'
} elseif($Kernel -eq 'KokoroAdaInLeaky16') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.AdaInLeaky16.ps1')
    $steps=@(New-KokoroAdaInLeaky16Steps -Channels $ConvInputChannels -Output $LeakyOutput -Identity:$LeakyIdentity)
    $symbol='kokoro_adain_leaky16'; $soname='libkokoro_adain_leaky16.so'
} elseif($Kernel -eq 'KokoroAdaInTurnsCoefficients') {
    . (Join-Path $PSScriptRoot '..' 'src' 'kernels' 'Kokoro.AdaInTurnsCoefficients.ps1')
    $steps=@(New-KokoroAdaInTurnsCoefficientsSteps -Channels $ConvChannels)
    $symbol='kokoro_adain_turns_coefficients'; $soname='libkokoro_adain_turns_coefficients.so'
} elseif($Kernel -eq 'KokoroHmxConvRun') {
    . (Join-Path $PSScriptRoot '..\src\jobs\Kokoro.HmxConvRun.ps1')
    $run=New-KokoroHmxConvRunSteps -Channels $ConvChannels -Kernel $ConvKernel -Dilation $ConvDilation -Tiles $ConvTiles
    $steps=@($run.Steps)
    $symbol='kokoro_hmx_conv_run_skel_handle_invoke'; $soname='libkokoro_hmx_conv_run_skel.so'
} elseif($Kernel -eq 'KokoroDmaCopy') {
    . (Join-Path $PSScriptRoot '..\src\hexagon\Kokoro.DmaCopy.ps1')
    $steps=@(New-KokoroDmaCopySteps)
    $symbol='kokoro_dma_copy'; $soname='libkokoro_dma_copy.so'
} elseif($Kernel -eq 'KokoroDmaBench') {
    . (Join-Path $PSScriptRoot '..\src\hexagon\Kokoro.DmaBenchProbe.ps1')
    $steps=@(New-KokoroDmaBenchSteps)
    $symbol='kokoro_dma_bench_skel_handle_invoke'; $soname='libkokoro_dma_bench_skel.so'
} elseif($Kernel -eq 'KokoroVtcmQuery') {
    . (Join-Path $PSScriptRoot '..\src\hexagon\Kokoro.VtcmQueryProbe.ps1')
    $steps=@(New-KokoroVtcmQuerySteps)
    $symbol='kokoro_vtcm_query_skel_handle_invoke'; $soname='libkokoro_vtcm_query_skel.so'
} elseif($Kernel -eq 'KokoroLinearTile') {
    . (Join-Path $PSScriptRoot '..\src\kernels\Kokoro.LinearTile.ps1')
    $steps=@(New-KokoroLinearTileSteps -Rows $LinearRows `
        -InputChannels $LinearInputChannels -OutputChannels $LinearOutputChannels `
        -VectorOutputTiles:$LinearVectorOutputTiles)
    $symbol='kokoro_linear_skel_handle_invoke'; $soname='libkokoro_linear_skel.so'
} else {
    $steps=@(New-HexagonProbeSteps)
    $symbol='kqnn_emit_skel_handle_invoke'; $soname='libkqnn_emit_skel.so'
}
if ($RegionBody) {
    # Close external control flow solely for independent encoding verification.
    # This has no RPC admission/open entry and must never be deployed as a worker.
    $steps+=@(@{Op='imm';d=0;i=0},@{Op='return'},@{Op='label';Name='encoding_domain'},@{Op='imm';d=0;i=33},@{Op='return'})
    $symbol+='_encoding_only'; $soname=$soname.Replace('_skel.so','_region_encoding_only.so')
}
$library=New-ElfCodeLibrary -Soname $soname -Needed @() -Functions ([ordered]@{$symbol=$steps}) -PageSize 4096
if($Kernel -in 'KokoroDecoder16Run','KokoroDecoderGenerator16Run','KokoroResBlockRun','KokoroGenerator60xRun','KokoroGenerator60xResidentRun','KokoroGenerator60x16Run','KokoroGeneratorTailRun','KokoroGeneratorTail16Run','KokoroGeneratorStage16TailRun','KokoroResBlock16Run','KokoroGeneratorFrontStageTailRun','KokoroGeneratorFront10x16Run','KokoroGeneratorWhole16Run','KokoroHarmonicStft16Run','KokoroHarmonicSource16Run','KokoroGeneratorWholeSource16Run') {
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'runner-link.json') ([Text.Encoding]::UTF8.GetBytes((@{Entry=$library.Exports[$symbol];Got=$library.GotSlots} | ConvertTo-Json -Depth 4))) -AllowOverwrite:$Force
}
$path=Join-Path $OutputDirectory $soname
Write-NewOrIdenticalFile $path $library.Bytes -AllowOverwrite:$Force
# GOT calls: give each step its resolved slot - pc so the independent assembly encodes the same bytes.
$isaLength=(Get-InstructionSet).Length
$pcAt=[long]$library.Exports[$symbol]
foreach($step in $steps) {
    if($step.Op -eq 'got-call') { $step.Delta=[long]$library.GotSlots[$step.Import]-$pcAt }
    $pcAt+=& $isaLength $step
}
$asm=@('.text','.p2align 2',".global $symbol",".type $symbol,@function","${symbol}:")
$asm+=@($steps | ForEach-Object {ConvertTo-HexagonAssembly $_})
Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'probe-reference.s') ([Text.Encoding]::UTF8.GetBytes(($asm -join "`n")+"`n")) -AllowOverwrite:$Force
$codeStart=[int]$library.Exports[$symbol]
$isa=Get-InstructionSet
$codeLength=($steps | Where-Object Op -ne 'label' | ForEach-Object { & $isa.Length $_ } | Measure-Object -Sum).Sum
$code=[byte[]]::new($codeLength); [Array]::Copy($library.Bytes,$codeStart,$code,0,$codeLength)
Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'emitted-code.bin') $code -AllowOverwrite:$Force
[pscustomobject]@{Path=$path;Bytes=$library.Bytes.Length;CodeBytes=$codeLength;SHA256=(Get-FileHash $path).Hash;Imports=$library.Imports.Count;Relocations=0;RegionBodyEncodingOnly=[bool]$RegionBody}
