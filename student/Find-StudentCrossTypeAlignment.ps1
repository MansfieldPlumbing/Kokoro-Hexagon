#requires -Version 7.7

param([Parameter(Mandatory)] $Speech, [ValidateRange(1,32)][int] $MemoryLimitGiB = 4)

class StudentTypedReferenceBearing {
    [object] $From
    [Reflection.PropertyInfo] $Member
    [object] $Referent
}

class StudentCrossTypeAlignment {
    [object] $Referent
    [Collections.Generic.Dictionary[type,Collections.Generic.List[StudentTypedReferenceBearing]]] $Bearings =
        [Collections.Generic.Dictionary[type,Collections.Generic.List[StudentTypedReferenceBearing]]]::new()
}

$identity = [Collections.Generic.ReferenceEqualityComparer]::Instance
$queue = [Collections.Generic.Queue[object]]::new()
$seen = [Collections.Generic.HashSet[object]]::new($identity)
$incoming = [Collections.Generic.Dictionary[object,StudentCrossTypeAlignment]]::new($identity)
$members = [Collections.Generic.Dictionary[type,Reflection.PropertyInfo[]]]::new()
foreach ($root in @($Speech.Inventory.Units.Values; $Speech.Documents; $Speech.Recordings;
        $Speech.HumanWordAnchors; $Speech.ConversationReadings; $Speech.ConversationEvents;
        $Speech.PrivateCues; $Speech.Comparisons)) {
    if ($null -ne $root -and $seen.Add($root)) { $queue.Enqueue($root) }
}
$visited = 0
while ($queue.Count) {
    $owner = $queue.Dequeue()
    $ownerType = $owner.GetType()
    if (!$members.ContainsKey($ownerType)) {
        $members[$ownerType] = @(foreach ($property in $ownerType.GetProperties()) {
            $targetType = $property.PropertyType
            if ($targetType.IsArray) { $targetType = $targetType.GetElementType() }
            # Keep native buffers, strings, and ordinary CLR containers out of the reference graph.
            if ($targetType.Assembly.IsDynamic -and $targetType.Name.StartsWith('Student',[StringComparison]::Ordinal)) {
                $property
            }
        })
    }
    foreach ($property in $members[$ownerType]) {
        $value = $property.GetValue($owner)
        if ($null -eq $value) { continue }
        foreach ($target in $value) {
            if ($null -eq $target) { continue }
            if ($seen.Add($target)) { $queue.Enqueue($target) }
            $alignment = $null
            if (!$incoming.TryGetValue($target,[ref]$alignment)) {
                $alignment = [StudentCrossTypeAlignment]::new()
                $alignment.Referent = $target
                $incoming.Add($target,$alignment)
            }
            $bucket = $null
            if (!$alignment.Bearings.TryGetValue($ownerType,[ref]$bucket)) {
                $bucket = [Collections.Generic.List[StudentTypedReferenceBearing]]::new()
                $alignment.Bearings.Add($ownerType,$bucket)
            }
            $bearing = [StudentTypedReferenceBearing]::new()
            $bearing.From = $owner
            $bearing.Member = $property
            $bearing.Referent = $target
            $bucket.Add($bearing)
        }
    }
    if (++$visited % 4096 -eq 0) {
        $process = [Diagnostics.Process]::GetCurrentProcess()
        try {
            if ($process.WorkingSet64 -ge $MemoryLimitGiB * 1GB) { throw 'Alignment exceeded its memory limit.' }
        } finally { $process.Dispose() }
        Write-Information ("{0:u} Cross-type scan visited {1} objects; {2} pending." -f
            [datetime]::UtcNow,$visited,$queue.Count) -InformationAction Continue
    }
}
$alignments = @(foreach ($alignment in $incoming.Values) {
    if ($alignment.Bearings.Count -gt 1) { $alignment }
})
[pscustomobject]@{ ObjectsVisited=$visited; AlignmentReferents=$alignments }
