#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$path = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', 'src', 'appliance', 'Kokoro.ApplianceExpression.ps1'))
$capability = [scriptblock]::Create([IO.File]::ReadAllText($path)).InvokeReturnAsIs()
& $capability.Verify
