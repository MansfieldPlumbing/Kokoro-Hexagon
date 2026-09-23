#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $PwshRoot = (Join-Path $PSScriptRoot '..\..\Pwsh'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\hexagon-emission\emitted'),
    [ValidateSet('Probe','KokoroAffine','KokoroConvTile')][string] $Kernel='Probe',
    [string] $WeightManifest=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\emit\r0\r0_static.json')
)
$ErrorActionPreference = 'Stop'
# Host-only. The pinned ELF writer uses .NET APIs requiring FullLanguage.
# No model text or external script input is executed by this adapter.
$setup = Join-Path $PwshRoot 'setup.ps1'
$manifestPath = Join-Path $PwshRoot 'lib\manifest.json'
if ((Get-FileHash $setup).Hash -ne '44432CB738EDB13FB7B2AEA999C265A94F5EEAC867DC4E4E39C1503E0E813D62') { throw 'Pwsh writer source pin mismatch' }
if ((Get-FileHash $manifestPath).Hash -ne 'C2B3C6D044EACBACAD7E7B1C58F18EA8AE6FB836B421B5EC3788D009E57CEDC4') { throw 'Pwsh manifest pin mismatch' }
$script:PwshLib = Join-Path $PwshRoot 'lib'
$script:PwshSources = (Get-Content $manifestPath -Raw | ConvertFrom-Json).sources
function Import-LibSourceText {
    param([string] $Path)
    $record = @($script:PwshSources | Where-Object path -CEQ $Path)
    if ($record.Count -ne 1) { throw "Missing source pin: $Path" }
    $file = Join-Path $script:PwshLib $Path
    if ((Get-FileHash $file).Hash -ne $record[0].sha256) { throw "Source hash mismatch: $Path" }
    [IO.File]::ReadAllText($file)
}
function Write-NewOrIdenticalFile {
    param([string] $Path, [byte[]] $Bytes)
    if ([IO.File]::Exists($Path)) {
        if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))) -ne
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))) { throw "Output exists with different bytes: $Path. Choose a new output directory." }
    } else { [IO.File]::WriteAllBytes($Path,$Bytes) }
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($setup,[ref]$tokens,[ref]$errors)
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
Write-NewOrIdenticalFile $adapter ([Text.Encoding]::UTF8.GetBytes($text))
. $adapter
. (Join-Path $PSScriptRoot '..\src\emit\Hexagon.ps1')
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
$script:Target=[pscustomobject]@{ElfClass=32;Machine='EM_HEXAGON';ElfFlags=@('EF_HEXAGON_ISA_V73');RelocationForm='RELA'}
if($Kernel -in 'KokoroAffine','KokoroConvTile') {
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
    . (Join-Path $PSScriptRoot '..\src\emit\Kokoro.Affine.ps1')
    $steps=@(New-KokoroAffineSteps -Nodes $nodes -Channels $weights.Channels -GainOffset $weights.Values.'adain1.0.gain'.Offset -ShiftOffset $weights.Values.'adain1.0.shift'.Offset -WeightBytes $weights.Bytes)
    $symbol='kqnn_affine_skel_handle_invoke'; $soname='libkqnn_affine_skel.so'
    } else {
        if(($weights.Values.'convs1.0.weight'.Shape -join ',') -ne '1,3,128,128' -or
            ($weights.Values.'convs1.0.bias'.Shape -join ',') -ne '128') { throw 'Unexpected convolution weight layout' }
        . (Join-Path $PSScriptRoot '..\src\emit\Kokoro.ConvTile.ps1')
        $steps=@(New-KokoroConvTileSteps -Nodes $nodes -Channels $weights.Channels -WeightOffset $weights.Values.'convs1.0.weight'.Offset -BiasOffset $weights.Values.'convs1.0.bias'.Offset -WeightBytes $weights.Bytes)
        $symbol='kokoro_conv_skel_handle_invoke'; $soname='libkokoro_conv_skel.so'
    }
    Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'lowered.json') ([Text.Encoding]::UTF8.GetBytes(($nodes | ConvertTo-Json -Depth 6)))
} else {
    $steps=@(New-HexagonProbeSteps)
    $symbol='kqnn_emit_skel_handle_invoke'; $soname='libkqnn_emit_skel.so'
}
$library=New-ElfCodeLibrary -Soname $soname -Needed @() -Functions ([ordered]@{$symbol=$steps}) -PageSize 4096
$path=Join-Path $OutputDirectory $soname
Write-NewOrIdenticalFile $path $library.Bytes
$asm=@('.text','.p2align 2',".global $symbol",".type $symbol,@function","${symbol}:")
$asm+=@($steps | ForEach-Object {ConvertTo-HexagonAssembly $_})
Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'probe-oracle.s') ([Text.Encoding]::UTF8.GetBytes(($asm -join "`n")+"`n"))
$codeStart=[int]$library.Exports[$symbol]
$codeLength=4*@($steps | Where-Object Op -ne 'label').Count
$code=[byte[]]::new($codeLength); [Array]::Copy($library.Bytes,$codeStart,$code,0,$codeLength)
Write-NewOrIdenticalFile (Join-Path $OutputDirectory 'emitted-code.bin') $code
[pscustomobject]@{Path=$path;Bytes=$library.Bytes.Length;CodeBytes=$codeLength;SHA256=(Get-FileHash $path).Hash;Imports=$library.Imports.Count;Relocations=0}
