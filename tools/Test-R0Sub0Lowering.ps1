#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot
$modelPath = Join-Path $root 'src\models\Kokoro.R0Sub0.ps1'
$tokens = $null; $errors = $null
$modelAst = [Management.Automation.Language.Parser]::ParseFile($modelPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'R0Sub0 model does not parse' }
$nodes = @(& (Join-Path $root 'src\lower\Lower-Model.ps1') -Model $modelAst.GetScriptBlock())

. (Join-Path $root 'src\emit\Kokoro.R0Sub0.ps1')
$steps = @(New-KokoroR0Sub0Steps -Nodes $nodes -WeightBytes 1195008)
$vectorRegisters = [Collections.Generic.HashSet[int]]::new()
foreach ($step in $steps) {
    if ($step.Op -notlike 'v*') { continue }
    foreach ($field in 'd','s','t') {
        if ($step.ContainsKey($field)) { [void]$vectorRegisters.Add([int]$step[$field]) }
    }
}
$actualRegisters = @($vectorRegisters | Sort-Object)
$expectedRegisters = @(0..29)
if (($actualRegisters -join ',') -cne ($expectedRegisters -join ',')) {
    throw "Unexpected vector register allocation: $($actualRegisters -join ',')"
}

$groupLabel = @($steps | Where-Object { $_.Op -eq 'label' -and $_.Name -eq 'group_loop' })
if ($groupLabel.Count -ne 1) { throw 'Eight-lane group loop is absent' }
$startTick = [Array]::FindIndex($steps, [Predicate[hashtable]]{ param($step) $step.Op -eq 'hwticks' -and $step.d -eq 2 })
$endTick = [Array]::FindIndex($steps, [Predicate[hashtable]]{ param($step) $step.Op -eq 'hwticks' -and $step.d -eq 0 })
if ($startTick -lt 0 -or $endTick -le $startTick) { throw 'Hardware timer boundary is invalid' }

[pscustomobject]@{
    Nodes = $nodes.Count
    VectorRegisters = $actualRegisters.Count
    HighestVectorRegister = $actualRegisters[-1]
    Steps = $steps.Count
    TimedInstructions = $endTick - $startTick - 1
}
