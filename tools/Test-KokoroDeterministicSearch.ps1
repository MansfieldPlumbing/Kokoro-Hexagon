#requires -Version 7.4
# Tests the reusable search transition using a transparent objective.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Join-Path $PSScriptRoot '../src/control/Kokoro.DeterministicSearch.psm1'
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Search module AST is invalid.'}
Import-Module $module -Force
$evaluate={param([double]$value) [pscustomobject]@{Score=[Math]::Abs($value-1.0)}}
$args=@{Evaluate=$evaluate;Initial=1.125;Step=0.0625;Minimum=0.75;Maximum=1.25;
    MaxEvaluations=16;MaxBacktracks=1;WorsePatience=3}
$first=Invoke-KokoroDeterministicSearch @args
$second=Invoke-KokoroDeterministicSearch @args
$sequence=@($first.Trials|ForEach-Object{"$($_.Coordinate):$($_.Decision)"})
if($first.BestCoordinate -ne 1.0 -or $first.Backtracks -ne 1 -or
    $first.Evaluations -ne 6 -or
    ($sequence -join ',') -cne '1.125:initial,1.0625:improved,1:improved,0.9375:worse,0.875:worse,0.8125:rollback_and_halve_step' -or
    ($sequence -join ',') -cne (@($second.Trials|ForEach-Object{"$($_.Coordinate):$($_.Decision)"}) -join ',')) {
    throw 'Deterministic path, benefit, or three-regression backtrack differs.'
}
$rejected=0
try {Invoke-KokoroDeterministicSearch @args -Maximum 0.8|Out-Null}catch{$rejected++}
try {Invoke-KokoroDeterministicSearch @args -Evaluate {param($x)[pscustomobject]@{Score=[double]::NaN}}|Out-Null}catch{$rejected++}
if($rejected -ne 2){throw 'Invalid evaluation was accepted.'}
[pscustomobject]@{Passed=$true;Evaluations=$first.Evaluations;Backtracks=$first.Backtracks;
    BestCoordinate=$first.BestCoordinate;Rejected=$rejected;Sequence=$sequence}
