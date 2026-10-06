# Return selected build-function definitions from the integrity-pinned Pwsh setup.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SetupPath,
    [Parameter(Mandatory)]
    [ValidateSet('Write-MicrosoftLambdaToMethodBuilder', 'Set-DeterministicMvid',
        'Write-ByteSpan', 'New-BinaryAxmlManifest', 'Get-ResourceChunkConstants',
        'Test-ResChunkHeader', 'Test-BinaryAxml', 'New-ResourceTable',
        'New-ResStringPool', 'Get-Crc32Table', 'Get-Crc32', 'Get-DeflatedBytes',
        'New-ApkArchive', 'Get-LengthPrefixed', 'Get-ApkContentDigest',
        'New-SignedApk', 'Test-SignedApk')]
    [string[]] $FunctionName,
    [string] $RepositoryRoot = [IO.Path]::GetFullPath(
        [IO.Path]::Combine($PSScriptRoot, '..', '..'))
)

Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$resolvedSetup = (Resolve-Path -LiteralPath $SetupPath).Path
$manifest = [IO.File]::ReadAllText(
    [IO.Path]::Combine($root, 'lib', 'manifest.json'),
    [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
$pin = @($manifest.pwshUpstream.files | Where-Object { $_.path -ceq 'setup.ps1' })
if ($pin.Count -ne 1) { throw 'The Pwsh setup source has no unique integrity pin.' }
$item = Get-Item -LiteralPath $resolvedSetup
$hash = (Get-FileHash -LiteralPath $resolvedSetup -Algorithm SHA256).Hash
if ($item.Length -ne [long]$pin[0].bytes -or $hash -cne [string]$pin[0].sha256) {
    throw 'The Pwsh setup source does not match its downstream integrity pin.'
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $resolvedSetup, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The pinned Pwsh setup source does not parse.' }

$definitions = foreach ($name in @($FunctionName | Sort-Object -Unique)) {
    $matches = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq $name
    }, $true))
    if ($matches.Count -ne 1) { throw "Pinned Pwsh build function '$name' is not unique." }
    $definitionTokens = $null
    $definitionErrors = $null
    $definitionAst = [Management.Automation.Language.Parser]::ParseInput(
        $matches[0].Extent.Text, [ref]$definitionTokens, [ref]$definitionErrors)
    if ($definitionErrors.Count -ne 0 -or
        $definitionAst.EndBlock.Statements.Count -ne 1 -or
        $definitionAst.EndBlock.Statements[0] -isnot
            [Management.Automation.Language.FunctionDefinitionAst]) {
        throw "Pinned Pwsh build function '$name' failed isolated AST validation."
    }
    $definitionAst.GetScriptBlock()
}

[pscustomobject]@{
    PSTypeName = 'Kokoro.Build.PwshFunctionImport'
    SetupSHA256 = $hash
    Names = [string[]]@($FunctionName | Sort-Object -Unique)
    Definitions = [scriptblock[]]@($definitions)
    Passed = $true
}
