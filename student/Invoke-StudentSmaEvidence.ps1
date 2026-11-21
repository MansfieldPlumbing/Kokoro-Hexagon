using module ./StudentSourceInventory.psm1
#requires -Version 7.4

[CmdletBinding(DefaultParameterSetName='Capture')]
param(
    [Parameter(Mandatory,ParameterSetName='Capture')][string[]] $SourceRoot,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [Parameter(Mandatory,ParameterSetName='Read')][switch] $Read
)

class StudentSmaEvidence {
    [StudentSourceUnit] $Source
    [Management.Automation.Language.ScriptBlockAst] $Ast
    [Management.Automation.Language.Token[]] $Tokens
    [Management.Automation.Language.ParseError[]] $Errors
    [type] $ParserType
}

$ErrorActionPreference = 'Stop'
$directory = [IO.Directory]::CreateDirectory($EvidenceDirectory).FullName
$index = Join-Path $directory 'sources.bin'
if ($Read) { $inventory = Open-StudentSourceInventory $index }
else {
    $inventory = [StudentSourceInventory]::new()
    foreach ($root in $SourceRoot) {
        $rootPath = (Resolve-Path -LiteralPath $root).Path
        foreach ($file in Get-ChildItem -LiteralPath $rootPath -File -Recurse) {
            if ($file.Extension -notin '.ps1','.psm1','.psd1') { continue }
            $relative = [IO.Path]::GetRelativePath($rootPath,$file.FullName)
            $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
            $sourceDirectory = [IO.Directory]::CreateDirectory((Join-Path $directory $hash)).FullName
            $retained = Join-Path $sourceDirectory $file.Name
            if (!(Test-Path -LiteralPath $retained)) { [IO.File]::Copy($file.FullName,$retained) }
            $id = "SMA/$rootPath/$relative/$hash"
            $source = Add-StudentSourceFile -Inventory $inventory -Id $id -Kind PowerShellOriginalSource `
                -Path $retained -EvidenceGroup $rootPath
            if ($source.Checksum -cne $hash) { throw 'Retained PowerShell source hash mismatch.' }
        }
    }
    Save-StudentSourceInventory $inventory $index
}
foreach ($source in $inventory.Units.Values) {
    if ((Get-FileHash -LiteralPath $source.Path).Hash -cne $source.Checksum) { throw 'Retained PowerShell source hash mismatch.' }
    $tokens = $null
    $errors = $null
    $observed = [StudentSmaEvidence]::new()
    $observed.Source = $source
    $observed.ParserType = [Management.Automation.Language.Parser]
    $observed.Ast = [Management.Automation.Language.Parser]::ParseFile($source.Path,[ref]$tokens,[ref]$errors)
    $observed.Tokens = $tokens
    $observed.Errors = $errors
    $observed
}
