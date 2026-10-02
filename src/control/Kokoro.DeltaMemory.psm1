#requires -Version 7.4
# Development-time, data-only experience retrieval. Not product dispatch,
# causal inference, model promotion, or a trained analogy model.
Set-StrictMode -Version Latest

function Assert-DeltaFacts($Facts) {
    if ($Facts -isnot [Collections.IDictionary] -or $Facts.Count -gt 16) { throw 'Invalid fact map.' }
    foreach ($key in $Facts.Keys) {
        if ($key -isnot [string] -or $key -cnotmatch '^[a-z][a-z0-9_.-]{0,63}$' -or
            $Facts[$key] -isnot [bool]) { throw 'Facts require bounded names and Boolean values.' }
    }
}

function Assert-DeltaRecord($Record) {
    $fields = @('Schema','DeltaId','ContextId','ArtifactSHA256','TransitionKind','ActionId',
        'BeforeFacts','GuardFacts','Outcome','EvidenceId','Sequence','ParameterDelta','PredictedCostMs','ObservedCostMs')
    if ($Record -isnot [Collections.IDictionary] -or $Record.Count -ne $fields.Count) { throw 'Invalid delta record.' }
    foreach ($field in $fields) { if (-not $Record.Contains($field)) { throw 'Missing delta field.' } }
    if ($Record.Schema -ne 1 -or $Record.Schema -isnot [int] -and $Record.Schema -isnot [long]) { throw 'Unknown schema.' }
    foreach ($field in 'DeltaId','ContextId','ActionId','TransitionKind','EvidenceId') {
        if ($Record[$field] -isnot [string] -or $Record[$field] -cnotmatch '^[a-z0-9][a-z0-9_.-]{0,127}$') { throw 'Invalid identity.' }
    }
    if ($Record.ArtifactSHA256 -isnot [string] -or $Record.ArtifactSHA256 -cnotmatch '^[A-F0-9]{64}$') { throw 'Invalid artifact identity.' }
    if ($Record.Sequence -isnot [int] -and $Record.Sequence -isnot [long] -or $Record.Sequence -lt 0) { throw 'Invalid sequence.' }
    if ($Record.Outcome -cnotin @('VerifiedBenefit','Regression','Incorrect','Blocked','Inconclusive')) { throw 'Invalid outcome.' }
    Assert-DeltaFacts $Record.BeforeFacts
    Assert-DeltaFacts $Record.GuardFacts
    foreach ($key in $Record.GuardFacts.Keys) {
        if (-not $Record.BeforeFacts.Contains($key) -or $Record.BeforeFacts[$key] -ne $Record.GuardFacts[$key]) { throw 'Guard must describe observed facts.' }
    }
    if ($Record.Outcome -ceq 'Blocked' -and $Record.GuardFacts.Count -eq 0) { throw 'Blocked requires an explicit observed guard.' }
    if ($Record.ParameterDelta -isnot [double] -and $Record.ParameterDelta -isnot [float] -and
        $Record.ParameterDelta -isnot [int] -and $Record.ParameterDelta -isnot [long] -or
        -not [double]::IsFinite([double]$Record.ParameterDelta) -or
        [Math]::Abs([double]$Record.ParameterDelta) -gt 100000) { throw 'Invalid parameter delta.' }
    foreach ($field in 'PredictedCostMs','ObservedCostMs') {
        $value = $Record[$field]
        if ($null -ne $value -and (($value -isnot [double] -and $value -isnot [int] -and $value -isnot [long]) -or
                -not [double]::IsFinite([double]$value) -or $value -lt 0 -or $value -gt 600000)) { throw 'Invalid cost observation.' }
    }
}

function Test-DeltaFactsEqual($Left, $Right) {
    if ($Left.Count -ne $Right.Count) { return $false }
    foreach ($key in $Left.Keys) { if (-not $Right.Contains($key) -or $Left[$key] -ne $Right[$key]) { return $false } }
    return $true
}

function Get-KokoroDeltaAdvice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Candidate,
        [AllowEmptyCollection()][object[]]$Records = @())
    # Candidate uses the same record schema, but is not evidence of an outcome.
    Assert-DeltaRecord $Candidate
    if ($Candidate.Outcome -cne 'Inconclusive') { throw 'Candidate must have no asserted outcome.' }
    if ($Records.Count -gt 4096) { throw 'Retrieval bound exceeded.' }
    $evidence = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sequences = [Collections.Generic.HashSet[long]]::new()
    foreach ($record in $Records) {
        Assert-DeltaRecord $record
        if (-not $evidence.Add($record.EvidenceId) -or -not $sequences.Add($record.Sequence)) { throw 'Duplicate evidence or sequence.' }
    }
    $exact = @($Records | Where-Object {
        $_.ContextId -ceq $Candidate.ContextId -and $_.ArtifactSHA256 -ceq $Candidate.ArtifactSHA256 -and
        $_.ActionId -ceq $Candidate.ActionId -and $_.DeltaId -ceq $Candidate.DeltaId -and
        $_.TransitionKind -ceq $Candidate.TransitionKind -and
        $_.ParameterDelta -eq $Candidate.ParameterDelta
    } | Sort-Object Sequence -Descending)
    $sameState = @($exact | Where-Object { Test-DeltaFactsEqual $_.BeforeFacts $Candidate.BeforeFacts })
    $decision = 'Test'; $reason = 'no_applicable_evidence'; $matches = @(); $streak = 0
    $outcomes = @($sameState | ForEach-Object { $_.Outcome } | Select-Object -Unique)
    if ('VerifiedBenefit' -cin $outcomes -and ('Incorrect' -cin $outcomes -or 'Blocked' -cin $outcomes)) {
        $decision = 'Abstain'; $reason = 'contradictory_evidence'; $matches = $sameState
    } elseif ('Incorrect' -cin $outcomes) {
        $decision = 'Suppress'; $reason = 'same_artifact_failed_correctness'; $matches = @($sameState | Where-Object Outcome -CEQ 'Incorrect')
    } else {
        foreach ($record in $exact | Where-Object Outcome -CEQ 'Blocked') {
            $known = $true; $equal = $true
            foreach ($key in $record.GuardFacts.Keys) {
                if (-not $Candidate.BeforeFacts.Contains($key)) { $known = $false }
                elseif ($Candidate.BeforeFacts[$key] -ne $record.GuardFacts[$key]) { $equal = $false }
            }
            if ($known -and $equal) { $decision = 'Suppress'; $reason = 'blocking_condition_unchanged'; $matches = @($record); break }
            if (-not $known) { $decision = 'Abstain'; $reason = 'blocking_condition_unknown'; $matches = @($record) }
            elseif ($decision -eq 'Test') { $decision = 'Reevaluate'; $reason = 'blocking_condition_changed'; $matches = @($record) }
        }
        if ($decision -eq 'Test') {
            foreach ($record in $sameState) { if ($record.Outcome -cne 'Regression') { break }; $streak++ }
            if ($streak -ge 3) { $decision = 'Suppress'; $reason = 'three_consecutive_regressions'; $matches = @($sameState | Select-Object -First $streak) }
            elseif ($sameState.Count -gt 0 -and $sameState[0].Outcome -ceq 'VerifiedBenefit') {
                $decision = 'PreferForTest'; $reason = 'prior_verified_benefit'; $matches = @($sameState[0])
            }
        }
    }
    # Explicitly authored role vocabulary supplies the abstraction. Matching
    # relational guards across contexts is a test proposal, never a hard veto.
    if ($decision -eq 'Test') {
        $analogies = @($Records | Where-Object {
            $_.ContextId -cne $Candidate.ContextId -and $_.TransitionKind -ceq $Candidate.TransitionKind -and
            $_.GuardFacts.Count -gt 0 -and (Test-DeltaFactsEqual $_.GuardFacts $Candidate.GuardFacts)
        } | Sort-Object Sequence -Descending | Select-Object -First 8)
        if ($analogies.Count) { $decision = 'InvestigateAnalogy'; $reason = 'shared_transition_and_guard'; $matches = $analogies }
    }
    [pscustomobject]@{ Decision=$decision; Reason=$reason; RegressionStreak=$streak;
        EvidenceIds=@($matches | ForEach-Object EvidenceId); MayExecute=$false; MayPromote=$false }
}

function Export-KokoroDeltaRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Record,
        [Parameter(Mandatory)][string]$Directory)
    Assert-DeltaRecord $Record
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 5 -Compress))
    if ($bytes.Length -gt 16384) { throw 'Record bound exceeded.' }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $root = [IO.Path]::GetFullPath($Directory)
    [void][IO.Directory]::CreateDirectory($root)
    $path = Join-Path $root ($digest+'.json')
    $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $path
}

function Import-KokoroDeltaRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = [IO.FileInfo]::new([IO.Path]::GetFullPath($Path))
    if (-not $file.Exists -or $file.Length -gt 16384 -or $file.Length -eq 0 -or $file.Name -cnotmatch '^[A-F0-9]{64}\.json$') { throw 'Invalid record file.' }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -gt 16384 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $file.BaseName) { throw 'Record integrity differs.' }
    $record = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 5
    Assert-DeltaRecord $record
    $record
}

Export-ModuleMember -Function Get-KokoroDeltaAdvice,Export-KokoroDeltaRecord,Import-KokoroDeltaRecord
