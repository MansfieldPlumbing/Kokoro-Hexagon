#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$path = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'appliance', 'Kokoro.ApplianceExpression.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Appliance expression does not parse.' }
$capability = $ast.GetScriptBlock().InvokeReturnAsIs()
$result = & $capability.Verify
if (($result.Operations -join ',') -cne 'status') {
    throw 'Appliance admitted an operation beyond the startup check.'
}
$result
