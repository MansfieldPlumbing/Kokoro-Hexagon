#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach ($name in @('ConvertTo-KokoroAdaIn.ps1', 'ConvertTo-KokoroAdaInStyle.ps1')) {
    $path = Join-Path $root "src/models/$name"
    if (-not [IO.File]::Exists($path)) { throw "An AdaIN stage has no explicit operator name: $name" }
}
$emitter = Join-Path $root 'src/emit/Kokoro.Affine.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($emitter, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'The AdaIN emitter does not parse.' }
$functions = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object Name)
if ($functions.Count -ne 1 -or $functions[0] -cne 'New-KokoroAdaInAffineSteps') {
    throw 'The AdaIN-specific emitter is published under a generic method name.'
}
Write-Output 'PASS: AdaIN-specific reference and emitted method names'
