# Metadata-only speech session reducer. No tensor or sample arithmetic belongs here.
Set-StrictMode -Version Latest

function New-KokoroSpeechSession {
    param($EngineDescriptor)
    $engineHash = ''
    $graphHash = ''
    $ready = $false
    $phase = 'NoModel'
    if ($null -ne $EngineDescriptor) {
        if ([string]$EngineDescriptor.Assembly -cne 'Dev.MansfieldPlumbing.Kokoro.Model' -or
            [string]$EngineDescriptor.SHA256 -notmatch '^[0-9A-F]{64}$' -or
            [string]$EngineDescriptor.GraphSHA256 -notmatch '^[0-9A-F]{64}$') {
            throw 'Engine descriptor identity is invalid.'
        }
        $engineHash = [string]$EngineDescriptor.SHA256
        $graphHash = [string]$EngineDescriptor.GraphSHA256
        $ready = [bool]$EngineDescriptor.SynthesisReady
        $phase = 'ModelAdmitted'
    }
    [pscustomobject]@{
        Schema = 1
        SessionId = [Guid]::NewGuid().ToString('N')
        Generation = 0L
        Phase = $phase
        EngineSHA256 = $engineHash
        GraphSHA256 = $graphHash
        SynthesisReady = $ready
        RequestId = ''
        PhonemeCount = 0
        ProducedFrames = 0L
        QueuedFrames = 0L
        ErrorCode = ''
    }
}

function Copy-KokoroSpeechSession {
    param([Parameter(Mandatory)] $Session)
    [pscustomobject]@{
        Schema = [int]$Session.Schema
        SessionId = [string]$Session.SessionId
        Generation = [long]$Session.Generation
        Phase = [string]$Session.Phase
        EngineSHA256 = [string]$Session.EngineSHA256
        GraphSHA256 = [string]$Session.GraphSHA256
        SynthesisReady = [bool]$Session.SynthesisReady
        RequestId = [string]$Session.RequestId
        PhonemeCount = [int]$Session.PhonemeCount
        ProducedFrames = [long]$Session.ProducedFrames
        QueuedFrames = [long]$Session.QueuedFrames
        ErrorCode = [string]$Session.ErrorCode
    }
}

function Move-KokoroSpeechSession {
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)]
        [ValidateSet('warm','warm-complete','request','pcm','complete','drained','cancel','fault','close')]
        [string] $Event,
        [hashtable] $Data = @{}
    )
    if ([int]$Session.Schema -ne 1 -or [string]$Session.SessionId -notmatch '^[a-f0-9]{32}$') {
        throw 'Speech session identity is invalid.'
    }
    $next = Copy-KokoroSpeechSession $Session
    switch ($Event) {
        'warm' {
            if ($next.Phase -cne 'ModelAdmitted' -or -not $next.SynthesisReady) {
                throw 'Only a synthesis-ready admitted model may begin warmup.'
            }
            $next.Phase = 'Warming'
        }
        'warm-complete' {
            if ($next.Phase -cne 'Warming') { throw 'Warmup completion is out of sequence.' }
            $next.Phase = 'Ready'
        }
        'request' {
            if ($next.Phase -cne 'Ready') { throw 'The speech session is not ready for a request.' }
            $requestId = [string]$Data.requestId
            [int]$phonemeCount = $Data.phonemeCount
            if ($requestId -notmatch '^[a-f0-9]{32}$' -or $phonemeCount -lt 1 -or $phonemeCount -gt 510) {
                throw 'Speech request metadata is invalid.'
            }
            $next.Generation++
            $next.Phase = 'Synthesizing'
            $next.RequestId = $requestId
            $next.PhonemeCount = $phonemeCount
            $next.ProducedFrames = 0
            $next.QueuedFrames = 0
            $next.ErrorCode = ''
        }
        'pcm' {
            if ($next.Phase -cne 'Synthesizing') { throw 'PCM metadata arrived outside synthesis.' }
            [long]$produced = $Data.producedFrames
            [long]$queued = $Data.queuedFrames
            if ($produced -lt $next.ProducedFrames -or $queued -lt 0 -or $queued -gt $produced) {
                throw 'PCM frame counters are not monotonic and bounded.'
            }
            $next.ProducedFrames = $produced
            $next.QueuedFrames = $queued
        }
        'complete' {
            if ($next.Phase -cne 'Synthesizing') { throw 'Synthesis completion is out of sequence.' }
            $next.Phase = if ($next.QueuedFrames -gt 0) { 'Draining' } else { 'Ready' }
            if ($next.Phase -ceq 'Ready') { $next.RequestId = ''; $next.PhonemeCount = 0 }
        }
        'drained' {
            if ($next.Phase -cne 'Draining') { throw 'Drain completion is out of sequence.' }
            $next.Phase = 'Ready'; $next.QueuedFrames = 0; $next.RequestId = ''; $next.PhonemeCount = 0
        }
        'cancel' {
            if ($next.Phase -notin @('Synthesizing','Draining')) { throw 'No active request can be cancelled.' }
            $next.Generation++
            $next.Phase = 'Ready'; $next.RequestId = ''; $next.PhonemeCount = 0
            $next.ProducedFrames = 0; $next.QueuedFrames = 0
        }
        'fault' {
            if ($next.Phase -ceq 'Closed') { throw 'A closed session cannot fault.' }
            $code = [string]$Data.code
            if ($code -notmatch '^[A-Z][A-Z0-9_]{0,63}$') { throw 'Fault code is invalid.' }
            $next.Phase = 'Faulted'; $next.ErrorCode = $code
            $next.RequestId = ''; $next.PhonemeCount = 0; $next.QueuedFrames = 0
        }
        'close' {
            if ($next.Phase -ceq 'Closed') { throw 'Speech session is already closed.' }
            $next.Phase = 'Closed'; $next.RequestId = ''; $next.PhonemeCount = 0
            $next.ProducedFrames = 0; $next.QueuedFrames = 0
        }
    }
    $next
}

function ConvertTo-KokoroFacadeState {
    param([Parameter(Mandatory)] $Session)
    switch ([string]$Session.Phase) {
        'NoModel' { New-KokoroFacadeState -Phase Initializing -Prompt 'No admitted Kokoro model is active.' -Detail 'Install and verify a signed model' -Progress 0 -ActionLabel 'CHECK MODEL' }
        'ModelAdmitted' { New-KokoroFacadeState -Phase Initializing -Prompt 'The model is admitted, but its synthesis graph is incomplete.' -Detail 'Speech remains disabled' -Progress 0 -ActionLabel 'VIEW ENGINE STATUS' }
        'Warming' { New-KokoroFacadeState -Phase Initializing -Prompt 'Preparing the resident DSP session.' -Detail 'Warming direct Hexagon state' -Progress 0.15 -ActionLabel 'PLEASE WAIT' }
        'Ready' { New-KokoroFacadeState -Phase Ready -Prompt 'Ready for an admitted phoneme request.' -Detail 'Direct speech session ready' -Progress 1 -ActionLabel 'SPEAK' }
        'Synthesizing' {
            $progress = if ($Session.PhonemeCount -gt 0) { [Math]::Min(0.95, 0.1 + ($Session.ProducedFrames / ([double]$Session.PhonemeCount * 1200))) } else { 0.1 }
            New-KokoroFacadeState -Phase Speaking -Prompt 'Synthesizing the current admitted request.' -Detail ("{0} frames produced" -f $Session.ProducedFrames) -Progress $progress -ActionLabel 'CANCEL'
        }
        'Draining' { New-KokoroFacadeState -Phase Speaking -Prompt 'Finishing queued audio.' -Detail ("{0} frames queued" -f $Session.QueuedFrames) -Progress 0.98 -ActionLabel 'CANCEL' }
        'Faulted' { New-KokoroFacadeState -Phase Error -Prompt 'The speech session stopped safely.' -Detail ([string]$Session.ErrorCode) -Progress 0 -ActionLabel 'VIEW DETAILS' }
        'Closed' { New-KokoroFacadeState -Phase Error -Prompt 'The speech session is closed.' -Detail 'Restart required' -Progress 0 -ActionLabel 'CLOSED' }
        default { throw 'Unknown speech session phase.' }
    }
}

Export-ModuleMember -Function New-KokoroSpeechSession, Move-KokoroSpeechSession,
    ConvertTo-KokoroFacadeState
