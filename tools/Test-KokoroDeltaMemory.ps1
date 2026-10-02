#requires -Version 7.4
# Synthetic tests of development-time delta retrieval; no DSP or learning claim.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module=Join-Path $repo 'src/control/Kokoro.DeltaMemory.psm1'
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($module,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Module AST is invalid.'}
Import-Module $module -Force
$checks=0
function New-Fixture([string]$Outcome='Inconclusive',[int]$Sequence=0) {
    @{Schema=1;DeltaId='candidate-a';ContextId='test-resource-a';ArtifactSHA256=('A'*64);
      TransitionKind='resource-admission';ActionId='acquire-resource';BeforeFacts=@{'resource.ready'=$false};
      GuardFacts=@{'resource.ready'=$false};Outcome=$Outcome;EvidenceId="synthetic-$Sequence";Sequence=$Sequence;
      ParameterDelta=0.125;PredictedCostMs=1.0;ObservedCostMs=$null}
}
function Assert-Decision($Candidate,$Records,[string]$Expected) {
    $result=Get-KokoroDeltaAdvice -Candidate $Candidate -Records $Records
    if($result.Decision -cne $Expected -or $result.MayExecute -or $result.MayPromote){throw "Advice differs: expected $Expected, got $($result.Decision)."}
    $script:checks++
}
$candidate=New-Fixture
$blocked=New-Fixture 'Blocked' 1
Assert-Decision $candidate @() 'Test'
Assert-Decision $candidate @($blocked) 'Suppress'
$candidate.BeforeFacts['unrelated.flag']=$true
Assert-Decision $candidate @($blocked) 'Suppress'
$candidate.BeforeFacts['resource.ready']=$true;$candidate.GuardFacts=@{'resource.ready'=$true}
Assert-Decision $candidate @($blocked) 'Reevaluate'
$candidate.BeforeFacts=@{};$candidate.GuardFacts=@{}
Assert-Decision $candidate @($blocked) 'Abstain'
$candidate=New-Fixture;$candidate.ContextId='test-resource-b'
Assert-Decision $candidate @($blocked) 'InvestigateAnalogy'
$candidate.TransitionKind='numeric-rewrite'
Assert-Decision $candidate @($blocked) 'Test'
$candidate=New-Fixture;$incorrect=New-Fixture 'Incorrect' 2
Assert-Decision $candidate @($incorrect) 'Suppress'
$candidate.ParameterDelta=0.25
Assert-Decision $candidate @($incorrect) 'Test'
$candidate.ParameterDelta=0.125
$candidate.ArtifactSHA256='B'*64
Assert-Decision $candidate @($incorrect) 'Test'
$candidate=New-Fixture
$regressions=@(New-Fixture 'Regression' 3;New-Fixture 'Regression' 4;New-Fixture 'Regression' 5)
Assert-Decision $candidate $regressions[0..1] 'Test'
Assert-Decision $candidate $regressions 'Suppress'
$benefit=New-Fixture 'VerifiedBenefit' 6
Assert-Decision $candidate @($regressions+$benefit) 'PreferForTest'
Assert-Decision $candidate @($incorrect,$benefit) 'Abstain'
Assert-Decision $candidate @((New-Fixture 'Inconclusive' 7)) 'Test'
$rejections=0
try {Get-KokoroDeltaAdvice -Candidate $candidate -Records @($blocked,$blocked)|Out-Null}catch{$rejections++}
$invalid=New-Fixture;$invalid.BeforeFacts['resource.ready']='false'
try {Get-KokoroDeltaAdvice -Candidate $invalid|Out-Null}catch{$rejections++}
$invalid=New-Fixture;$invalid.ObservedCostMs=[double]::NaN
try {Get-KokoroDeltaAdvice -Candidate $invalid|Out-Null}catch{$rejections++}
$invalid=New-Fixture;$invalid.Schema=2
try {Get-KokoroDeltaAdvice -Candidate $invalid|Out-Null}catch{$rejections++}
$out=Join-Path $repo ('build/delta-memory-'+[Guid]::NewGuid().ToString('N'))
$path=Export-KokoroDeltaRecord -Record $blocked -Directory $out
$roundtrip=Import-KokoroDeltaRecord -Path $path
Assert-Decision $candidate @($roundtrip) 'Suppress'
try {Export-KokoroDeltaRecord -Record $blocked -Directory $out|Out-Null}catch{$rejections++}
if($rejections -ne 5){throw 'Invalid-input or overwrite rejection differs.'}
[pscustomobject]@{Passed=$true;BehaviorChecks=$checks;Rejections=$rejections;RecordPath=$path;
    Scope='synthetic_development_delta_memory';ProductDispatch=$false}
