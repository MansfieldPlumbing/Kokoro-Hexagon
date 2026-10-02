#requires -Version 7.4
[CmdletBinding()]
param([string] $AssemblyPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
Import-Module ([IO.Path]::Combine($root, 'src', 'appliance', 'Kokoro.Facade.psm1')) -Force
Import-Module ([IO.Path]::Combine($root, 'src', 'control', 'Kokoro.SpeechSession.psm1')) -Force

$none = New-KokoroSpeechSession
if ($none.Phase -cne 'NoModel' -or (ConvertTo-KokoroFacadeState $none).ActionLabel -cne 'CHECK MODEL') {
    throw 'The no-model session did not fail closed.'
}
$actualEngineVerified = $false
$current = if ([string]::IsNullOrWhiteSpace($AssemblyPath)) {
    [pscustomobject]@{
        Assembly = 'Dev.MansfieldPlumbing.Kokoro.Model'
        SHA256 = 'A' * 64
        GraphSHA256 = 'B' * 64
        SynthesisReady = $false
    }
}
else {
    $receipt = & ([IO.Path]::Combine($PSScriptRoot, 'Test-KokoroEngineAssembly.ps1')) -AssemblyPath $AssemblyPath
    if (-not $receipt.Passed -or $receipt.SynthesisReady) { throw 'The current engine receipt differs from the incomplete boundary.' }
    $actualEngineVerified = $true
    $receipt
}
$incomplete = New-KokoroSpeechSession $current
$rejected = $false
try { $null = Move-KokoroSpeechSession $incomplete warm } catch { $rejected = $true }
if (-not $rejected -or (ConvertTo-KokoroFacadeState $incomplete).ActionLabel -cne 'VIEW ENGINE STATUS') {
    throw 'The incomplete engine admitted warmup or projected a ready facade.'
}

$future = $current.PSObject.Copy(); $future.SynthesisReady = $true
$session = New-KokoroSpeechSession $future
$session = Move-KokoroSpeechSession $session warm
$session = Move-KokoroSpeechSession $session 'warm-complete'
$requestId = [Guid]::NewGuid().ToString('N')
$session = Move-KokoroSpeechSession $session request @{ requestId=$requestId; phonemeCount=12 }
$session = Move-KokoroSpeechSession $session pcm @{ producedFrames=2400L; queuedFrames=480L }
if ($session.Phase -cne 'Synthesizing' -or $session.Generation -ne 1 -or
    (ConvertTo-KokoroFacadeState $session).Phase -cne 'Speaking') {
    throw 'The active request state differs.'
}
$session = Move-KokoroSpeechSession $session complete
$session = Move-KokoroSpeechSession $session drained
if ($session.Phase -cne 'Ready' -or $session.RequestId.Length -ne 0) { throw 'Drain did not return the session to ready.' }

$session = Move-KokoroSpeechSession $session request @{ requestId=([Guid]::NewGuid().ToString('N')); phonemeCount=4 }
$session = Move-KokoroSpeechSession $session cancel
if ($session.Phase -cne 'Ready' -or $session.Generation -ne 3) { throw 'Latest-wins cancellation did not advance generation.' }
$rejected = $false
try { $null = Move-KokoroSpeechSession $session pcm @{ producedFrames=1L; queuedFrames=0L } } catch { $rejected = $true }
if (-not $rejected) { throw 'PCM metadata was accepted without active synthesis.' }

[pscustomobject]@{
    IncompleteEngineFailsClosed = $true
    ActualEngineVerified = $actualEngineVerified
    ReadyTransitionVerified = $true
    PcmCountersVerified = $true
    LatestWinsGeneration = $session.Generation
    FacadeProjectionVerified = $true
    CarriesSamples = $false
    Passed = $true
}
