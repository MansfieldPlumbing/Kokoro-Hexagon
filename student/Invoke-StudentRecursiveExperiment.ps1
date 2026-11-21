#requires -Version 7.7

[CmdletBinding()]
param(
    [string] $BankPath = (Join-Path $PSScriptRoot '../data/source-bank'),
    [string] $CheckpointDirectory,
    [ValidateRange(0,168)][double] $Hours = 0,
    [ValidateRange(64,1024)][int] $CheckpointLimitMiB = 64,
    [ValidateRange(1,32)][int] $MemoryLimitGiB = 4
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Invoke-StudentPerceptHunt.ps1" -Library
$workerLock = $null
$completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$checkpointBytes = 0L
if ($CheckpointDirectory) {
    $directory = [IO.Directory]::CreateDirectory($CheckpointDirectory).FullName
    $workerLock = [IO.File]::Open((Join-Path $directory 'worker.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    foreach ($entry in [IO.Directory]::EnumerateFiles($directory, '*.bin')) {
        $null = $completed.Add([IO.Path]::GetFileNameWithoutExtension($entry))
        $checkpointBytes += [IO.FileInfo]::new($entry).Length
    }
}
if ($Hours -and !$workerLock) { throw 'An unattended run requires a checkpoint directory.' }
try {
$pin = (Get-FileHash -LiteralPath (Join-Path $BankPath 'sources.bin')).Hash
$methodPin = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$started = [Diagnostics.Stopwatch]::StartNew()
Write-Information "Opening the retained typed evidence for a $Hours-hour worker." -InformationAction Continue
$speech = & "$PSScriptRoot/Open-StudentSpeechInvestigation.ps1" -BankPath $BankPath
$watch = [Diagnostics.Stopwatch]::StartNew()
Write-Information "Opened $($speech.Executions.Count) executions and $($speech.Inventory.Units.Count) source units." -InformationAction Continue

# Keep acquisition lineage separate from utterance, passage and descriptor identity.
$cohorts = @(
    @{ Rows = $speech.Inventory.Units.Values; Source = { param($row) $row }; Family = { param($row) $row.EvidenceGroup } }
    @{ Rows = $speech.Documents; Source = { param($row) $row.Source }; Family = { param($row) $row.Source.EvidenceGroup } }
    @{ Rows = $speech.Recordings; Source = { param($row) $row.Source }; Family = { param($row) $row.Source.EvidenceGroup } }
    @{ Rows = $speech.Recordings.Prosody; Source = { param($row) $row.Source }; Family = { param($row) $row.Source.EvidenceGroup } }
    @{ Rows = $speech.Comparisons.Teacher; Source = { param($row) $row.Document.Source }; Family = { 'Paired teacher pipeline' } }
    @{ Rows = $speech.Executions.Activations; Source = { param($row) $row.Execution.Teacher.Document.Source }; Family = { 'Stock capture lineage' } }
    @{ Rows = $speech.HumanWordAnchors; Source = { param($row) $row.Utterance.Chapter.Wave.Source }; Family = { param($row) $row.Utterance.Chapter.Wave.Source.EvidenceGroup } }
    @{ Rows = $speech.ConversationEvents; Source = { param($row) $row.Recording.Source }; Family = { param($row) $row.Recording.Source.EvidenceGroup } }
)

$screen = [Collections.Generic.List[object]]::new()
foreach ($cohort in $cohorts) {
    $rows = @($cohort.Rows | Where-Object { $null -ne $_ })
    if (!$rows.Count) { continue }
    $type = $rows[0].GetType()
    $members = @($type.GetProperties() | Where-Object PropertyType -In ([int], [long], [double], [single]))
    if ($members.Count -lt 2) { continue }
    $axes = @(foreach ($member in $members) {
        $axis = [HuntAxis]::new()
        $axis.Name = $member.Name
        $axis.SemanticMember = $member
        $axis
    })
    $families = [Collections.Generic.Dictionary[string,HuntBlock]]::new([StringComparer]::Ordinal)
    $cases = [Collections.Generic.List[HuntCase]]::new()
    $sourceOf = $cohort.Source
    $familyOf = $cohort.Family
    foreach ($row in $rows) {
        $source = & $sourceOf $row
        $family = & $familyOf $row
        if (!$family -and $source.Parent) { $family = $source.Parent.EvidenceGroup }
        if (!$family -or !$source) { continue }
        if (!$families.ContainsKey($family)) {
            $root = [HuntOrigin]::new()
            $root.Source = $source
            $root.EvidenceFamily = $family
            $block = [HuntBlock]::new()
            $block.Owner = $root
            $block.Identity = $family
            $block.Roots = @($root)
            $families.Add($family,$block)
        }
        $case = [HuntCase]::new()
        $case.Referent = $row
        $case.Context = $type
        $case.Block = $families[$family]
        $case.Readings = @(foreach ($axis in $axes) {
            $value = $axis.SemanticMember.GetValue($row)
            if (![double]::IsFinite($value)) { continue }
            $reading = [HuntReading]::new()
            $reading.Axis = $axis
            $reading.Observation = $row
            $reading.Coordinate = $source
            $reading.Value = $value
            $reading
        })
        $cases.Add($case)
    }
    # Give each origin family an entire partition. Candidate answers never determine placement.
    $partition = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($family in $families.Keys) {
        $key = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($family))
        if (($key[0] -band 1) -eq 0) { $null = $partition.Add($family) }
    }
    $record = [ordered]@{ Type=$type.Name; Objects=$rows.Count; Aligned=$cases.Count; Families=$families.Count
        DiscoveryFamilies=$partition.Count; HoldoutFamilies=$families.Count-$partition.Count
        Frozen=0; Nominated=0; Insufficient=0; Contradicted=0; Judgments=@() }
    $screen.Add([pscustomobject]$record)
    $summary = $screen[$screen.Count-1]
    if ($summary.DiscoveryFamilies -lt 3 -or $summary.HoldoutFamilies -lt 3) {
        Write-Information "$($type.Name) has $($summary.Families) provenance families in $($rows.Count) rows. The independent partition is insufficient." -InformationAction Continue
        continue
    }
    $discovery = @($cases | Where-Object { $partition.Contains($_.Block.Identity) })
    $heldOut = @($cases | Where-Object { !$partition.Contains($_.Block.Identity) })
    $inputs = @($axes | Where-Object { $_.SemanticMember.PropertyType -eq [int] })
    if (!$inputs.Count) { continue }
    $hypotheses = @(Find-HuntPattern ([HuntSession]::new()) $discovery $inputs $axes 1e-7 -MaxCandidates ($axes.Count * $inputs.Count))
    $summary.Frozen = $hypotheses.Count
    $judged = @(foreach ($pattern in $hypotheses) {
        if ($Hours -and $started.Elapsed.TotalHours -ge $Hours) { break }
        $keyText = "$pin/$methodPin/$($type.FullName)/$($pattern.InputAxis.Name)/$($pattern.OutputAxis.Name)"
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyText)))
        if ($completed.Contains($key)) { continue }
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try { $workingSet = $process.WorkingSet64 } finally { $process.Dispose() }
        if ($workingSet -ge $MemoryLimitGiB * 1GB -or $checkpointBytes + 4096 -ge $CheckpointLimitMiB * 1MB) {
            throw 'Investigation reached its configured memory or checkpoint limit.'
        }
        $trialWatch = [Diagnostics.Stopwatch]::StartNew()
        $allocationStart = [GC]::GetTotalAllocatedBytes($true)
        $failure = ''
        $outcome = $null
        try {
        $observations = @(foreach ($case in $heldOut) {
            $projection = [HuntCase]::new()
            $projection.Context = $case.Context
            $projection.Block = $case.Block
            $projection.Readings = $case.Readings
            $projection.Referent = [HuntPredictiveScalar]::new($case.Find($pattern.InputAxis).Value)
            $projection
        })
        $input = @(foreach ($case in $observations) { New-HuntInput $case $pattern.OutputAxis $pattern.InputAxis })
        $epoch = Start-HuntJudgment ([HuntSession]::new()) @($pattern) $input
        $outcome = Complete-HuntJudgment $epoch $observations
        } catch {
            $failure = $_.Exception.GetType().FullName
            Write-Information "Investigation $key failed with $failure" -InformationAction Continue
        }
        if ($workerLock) {
            $destination = Join-Path $directory "$key.bin"
            $temporary = "$destination.partial"
            $writer = [IO.BinaryWriter]::new([IO.File]::Open($temporary,'Create','Write','None'))
            try {
                $writer.Write('StudentInvestigation/1')
                $writer.Write($keyText)
                $writer.Write([datetime]::UtcNow.Ticks)
                $writer.Write($trialWatch.Elapsed.Ticks)
                $writer.Write([GC]::GetTotalAllocatedBytes($true)-$allocationStart)
                $writer.Write($failure)
                $writer.Write([double]$pattern.Slope)
                $writer.Write([double]$pattern.Offset)
                $writer.Write([string]$pattern.Current.Reliance)
                $writer.Write([double]$pattern.Current.AdjustedP)
                $writer.Write([int]$pattern.Current.OriginFamilies)
                $writer.Write([int]$pattern.Current.OutsideBound)
            } finally { $writer.Dispose() }
            [IO.File]::Move($temporary,$destination)
            $checkpointBytes += [IO.FileInfo]::new($destination).Length
        }
        $null = $completed.Add($key)
        if ($outcome) { $outcome }
    })
    $summary.Judgments = $judged
    $summary.Nominated = @($judged | Where-Object { $_.Current.Reliance -eq 'Nominated' }).Count
    $summary.Insufficient = @($judged | Where-Object { $_.Current.Reliance -eq 'Insufficient' }).Count
    $summary.Contradicted = @($judged | Where-Object { $_.Current.OutsideBound -gt 0 }).Count
}

$scopeResults = @{}
$scopeHistory = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
if ($workerLock) {
    foreach ($path in [IO.Directory]::EnumerateFiles($directory, '*.bin')) {
        $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($path))
        try {
            if ($reader.ReadString() -cne 'StudentStockScopeInvestigation/1') { continue }
            $identity = $reader.ReadString()
            $parts = $identity.Split('/',4)
            if ($parts.Count -ne 4 -or $parts[0] -cne $pin -or $parts[2] -cne 'StockScope') { continue }
            $null = $reader.ReadInt64()
            $null = $reader.ReadInt64()
            $null = $reader.ReadInt64()
            $scopeHistory[$parts[3]] = $reader.ReadString()
        } finally { $reader.Dispose() }
    }
    $scopes = [Collections.Generic.Dictionary[string,Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
    foreach ($activation in $speech.Executions.Activations) {
        $scope = "$($activation.Axes)`n$($activation.Stage)"
        if (!$scopes.ContainsKey($scope)) { $scopes.Add($scope,[Collections.Generic.List[object]]::new()) }
        $scopes[$scope].Add($activation)
    }
    # The largest reusable scopes have the greatest potential for avoiding repeated work.
    $ranked = $scopes.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending
    foreach ($scope in $ranked) {
        if ($Hours -and $started.Elapsed.TotalHours -ge $Hours) { break }
        if ($scopeHistory.ContainsKey($scope.Key)) { continue }
        $keyText = "$pin/$methodPin/StockScope/$($scope.Key)"
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyText)))
        if ($completed.Contains($key)) { continue }
        if ($checkpointBytes + 4096 -ge $CheckpointLimitMiB * 1MB) { break }
        $trialWatch = [Diagnostics.Stopwatch]::StartNew()
        $allocationStart = [GC]::GetTotalAllocatedBytes($true)
        $status = 'InsufficientVariation'
        $n = 0
        $rate = 0.0
        $misses = 0
        $novel = $false
        $basis = $scope.Value[0]
        foreach ($observation in $scope.Value) {
            if ($observation.Extent -ne $basis.Extent) { $novel = $true }
            if ([long]$observation.Count * $basis.Extent -ne [long]$basis.Count * $observation.Extent) { $misses++ }
            $n++
        }
        if ($novel) {
            $rate = $basis.Count / [double]$basis.Extent
            $status = if ($misses) { 'ContradictedInScope' } else { 'ObservedSingleLineage' }
        }
        $destination = Join-Path $directory "$key.bin"
        $temporary = "$destination.partial"
        $writer = [IO.BinaryWriter]::new([IO.File]::Open($temporary,'Create','Write','None'))
        try {
            $writer.Write('StudentStockScopeInvestigation/1')
            $writer.Write($keyText)
            $writer.Write([datetime]::UtcNow.Ticks)
            $writer.Write($trialWatch.Elapsed.Ticks)
            $writer.Write([GC]::GetTotalAllocatedBytes($true)-$allocationStart)
            $writer.Write($status)
            $writer.Write($basis.Checksum)
            $writer.Write($n)
            $writer.Write($rate)
            $writer.Write($misses)
        } finally { $writer.Dispose() }
        [IO.File]::Move($temporary,$destination)
        $checkpointBytes += [IO.FileInfo]::new($destination).Length
        $null = $completed.Add($key)
        $scopeResults[$status]++
        $scopeHistory[$scope.Key] = $status
        if ($completed.Count % 100 -eq 0) {
            Write-Information "Checkpointed $($completed.Count) investigations using $checkpointBytes bytes." -InformationAction Continue
        }
    }

    # Prior contradictions and repeated payloads expose follow-up scopes through their live owners.
    $opportunities = [Collections.Generic.PriorityQueue[object,long]]::new()
    foreach ($scope in $ranked) {
        if ($scopeHistory[$scope.Key] -cne 'ContradictedInScope') { continue }
        $opportunities.Enqueue(@{ Kind='ClockRefinement'; Id=$scope.Key; Rows=$scope.Value }, -$scope.Value.Count)
    }
    foreach ($group in $speech.ActivationInterpretations.Values) {
        $count = 0
        foreach ($bucket in $group.ByAxes.Values) { $count += $bucket.Count }
        if ($count -lt 2) { continue }
        $opportunities.Enqueue(@{ Kind='PayloadInterpretation'; Id=$group.PayloadDigest; Group=$group }, -$count)
    }
    $crossType = & "$PSScriptRoot/Find-StudentCrossTypeAlignment.ps1" -Speech $speech -MemoryLimitGiB $MemoryLimitGiB
    $crossTypeGroups = [Collections.Generic.Dictionary[string,Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
    foreach ($alignment in $crossType.AlignmentReferents) {
        $members = @(foreach ($bucket in $alignment.Bearings.Values) {
            foreach ($bearing in $bucket) {
                "$($bearing.Member.DeclaringType.FullName).$($bearing.Member.Name)"
            }
        }) | Sort-Object -Unique -CaseSensitive
        $signature = "$($alignment.Referent.GetType().FullName) <- $($members -join ', ')"
        if (!$crossTypeGroups.ContainsKey($signature)) { $crossTypeGroups.Add($signature,[Collections.Generic.List[object]]::new()) }
        $crossTypeGroups[$signature].Add($alignment)
    }
    foreach ($group in $crossTypeGroups.GetEnumerator()) {
        $opportunities.Enqueue(@{ Kind='CrossTypeBearing'; Id=$group.Key; Rows=$group.Value }, -$group.Value.Count)
    }
    Write-Information ("{0:u} Aligned {1} shared referents across CLR types in {2} structural groups ({3} objects visited)." -f
        [datetime]::UtcNow,$crossType.AlignmentReferents.Count,$crossTypeGroups.Count,$crossType.ObjectsVisited) -InformationAction Continue
    Write-Information ("{0:u} Loaded {1} prior scope judgments and queued {2} follow-ups." -f
        [datetime]::UtcNow,$scopeHistory.Count,$opportunities.Count) -InformationAction Continue
    while ($opportunities.Count) {
        if (($Hours -and $started.Elapsed.TotalHours -ge $Hours) -or
            $checkpointBytes + 4096 -ge $CheckpointLimitMiB * 1MB) { break }
        $opportunity = $opportunities.Dequeue()
        $identity = "$pin/Followup1/$($opportunity.Kind)/$($opportunity.Id)"
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
        if ($completed.Contains($key)) { continue }
        $trialWatch = [Diagnostics.Stopwatch]::StartNew()
        $allocated = [GC]::GetTotalAllocatedBytes($true)
        $rows = 0
        $alternatives = 0
        $conflicts = 0
        $reason = ''
        try {
            if ($opportunity.Kind -eq 'PayloadInterpretation') {
                $group = $opportunity.Group
                $alternatives = $group.ByAxes.Count
                foreach ($bucket in $group.ByAxes.Values) {
                    $rows += $bucket.Count
                    $first = $bucket[0]
                    foreach ($entry in $bucket) {
                        if ($entry.TypeCode -ne $first.TypeCode -or $entry.Count -ne $first.Count -or
                            $entry.Extent -ne $first.Extent) { $conflicts++ }
                    }
                }
                $reason = if ($alternatives -gt 1) { 'DistinctAxes' } elseif ($conflicts) { 'DistinctSameAxisGeometry' } else { 'SameDeclaredGeometry' }
            } elseif ($opportunity.Kind -eq 'CrossTypeBearing') {
                foreach ($alignment in $opportunity.Rows) {
                    $rows++
                    $alternatives = [Math]::Max($alternatives,$alignment.Bearings.Count)
                    foreach ($bucket in $alignment.Bearings.Values) {
                        foreach ($bearing in $bucket) {
                            if (![object]::ReferenceEquals($bearing.Referent,$alignment.Referent)) { $conflicts++ }
                        }
                    }
                }
                $reason = if ($conflicts) { 'ReferenceContradiction' } else { 'SharedCanonicalReferent' }
            } else {
                $partitions = @{}
                foreach ($entry in $opportunity.Rows) {
                    $clock = $entry.FrameClock()
                    $rows++
                    $context = if ($clock) { "$($clock.Basis)/$($clock.SamplesPerFrame)/$($clock.ReflectedPrefixFrames)" } else { 'Unestablished' }
                    if (!$partitions.ContainsKey($context)) { $partitions[$context] = $entry; continue }
                    $first = $partitions[$context]
                    if ([long]$entry.Count*$first.Extent -ne [long]$first.Count*$entry.Extent) { $conflicts++ }
                }
                $alternatives = $partitions.Count
                $reason = if ($conflicts) { 'ContradictionSurvivesClockPartition' }
                    elseif ($alternatives -gt 1) { 'ClockPartitionSeparatesObservations' } else { 'NoDiscriminatingClock' }
            }
        } catch { $reason = "Failed/$($_.Exception.GetType().Name)" }
        $destination = Join-Path $directory "$key.bin"
        $temporary = "$destination.partial"
        $writer = [IO.BinaryWriter]::new([IO.File]::Open($temporary,'Create','Write','None'))
        try {
            $writer.Write('StudentTypedFollowup/1')
            $writer.Write($identity)
            $writer.Write([datetime]::UtcNow.Ticks)
            $writer.Write($trialWatch.Elapsed.Ticks)
            $writer.Write([GC]::GetTotalAllocatedBytes($true)-$allocated)
            $writer.Write($reason)
            $writer.Write($rows)
            $writer.Write($alternatives)
            $writer.Write($conflicts)
        } finally { $writer.Dispose() }
        [IO.File]::Move($temporary,$destination)
        $checkpointBytes += [IO.FileInfo]::new($destination).Length
        $null = $completed.Add($key)
        if ($reason -cne 'SameDeclaredGeometry' -or $completed.Count % 100 -eq 0) {
            Write-Information ("{0:u} {1} {2} ({3} observations, {4} alternatives, {5} conflicts); {6} pending" -f
                [datetime]::UtcNow,$opportunity.Kind,$reason,$rows,$alternatives,$conflicts,$opportunities.Count) -InformationAction Continue
        }
        if ($opportunity.Kind -eq 'CrossTypeBearing') { Write-Information "  $($opportunity.Id)" -InformationAction Continue }
    }
}
[pscustomobject]@{
    PSTypeName = 'Kokoro.StudentRecursiveExperiment'
    CandidateScreen = $screen.ToArray()
    ScreeningTime = $watch.Elapsed
    CompletedJudgments = $completed.Count
    CheckpointBytes = $checkpointBytes
    StockScopeResults = $scopeResults
}
if ($Hours) {
    Write-Information "Investigation queue closed with $($opportunities.Count) queued and $($completed.Count) checkpointed." -InformationAction Continue
    while ($started.Elapsed.TotalHours -lt $Hours) {
        Start-Sleep -Seconds 60
        Write-Information ("{0:u} Waiting; checkpointed={1}, checkpoint bytes={2}." -f
            [datetime]::UtcNow,$completed.Count,$checkpointBytes) -InformationAction Continue
    }
}
} finally {
    if ($workerLock) { $workerLock.Dispose() }
}
