#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string] $AssemblyPath)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path -LiteralPath $AssemblyPath).Path
$bytes = [IO.File]::ReadAllBytes($path)
$assembly = [Reflection.Assembly]::Load($bytes)
if ($assembly.GetManifestResourceNames().Count -ne 0 -or
    @($assembly.GetReferencedAssemblies() | Where-Object Name -in 'System.Management.Automation', 'System.Text.Json').Count) {
    throw 'The seed must load as CLR types and IL alone.'
}
$rootType = $assembly.GetType('StudentPerceptSeed', $true)
$seed = $rootType.GetMethod('Read').Invoke($null, $null)
if ($seed.GetType() -ne $rootType -or $seed.Percepts.Count -ne 7 -or $seed.Evidence.Count -ne 46) {
    throw 'The compiled checkpoint has an unexpected shape.'
}
if (![object]::ReferenceEquals($seed.Occurrence, $seed.Percepts[0])) { throw 'Root identity was lost.' }
$byId = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
foreach ($observation in $seed.Evidence) { $byId.Add($observation.Identity, $observation) }
foreach ($node in $seed.Percepts) {
    foreach ($child in $node.Children) {
        if (![object]::ReferenceEquals($child.Parent, $node)) { throw 'The parent and child cycle was lost.' }
    }
    foreach ($observation in $node.Examples) {
        if (![object]::ReferenceEquals($byId[$observation.Identity], $observation)) { throw 'Shared observation identity was lost.' }
    }
}

$onsets = @($seed.Evidence | Where-Object { $null -ne $_.OnsetMilliseconds })
$frames = @($seed.Evidence | Where-Object { $null -ne $_.Frames })
$transfer = @($seed.Evidence | Where-Object Transfer)[0].Transfer
if ($onsets.Count -ne 18 -or $frames.Count -ne 18 -or $transfer.Fit.Count -ne 3 -or $transfer.Test.Count -ne 3 -or
    $transfer.Samples -ne 61800 -or $transfer.AddedFrames -ne 32 -or $transfer.HeldOutMAEms -ne 65 -or
    $transfer.ZeroEffectMAEms -ne 735) { throw 'Clock measurements differ from the checkpoint.' }
foreach ($onset in $onsets) {
    $match = @($frames | Where-Object { $_.Mark -ceq $onset.Mark -and [object]::ReferenceEquals($_.Prompt, $onset.Prompt) })
    if ($match.Count -ne 1) { throw 'The cross-engine prompt pairing was lost.' }
}
foreach ($row in @($transfer.Fit) + @($transfer.Test)) {
    if (!@($onsets | Where-Object { [object]::ReferenceEquals($_.Prompt, $row.Prompt) }).Count) {
        throw 'A held-out transfer row lost its prompt.'
    }
}

$alignments = @($seed.Evidence | Where-Object Alignment | ForEach-Object Alignment)
$gaps = @($seed.Evidence | Where-Object Acoustics | ForEach-Object { $_.Acoustics.Gaps })
$wordCount = 0
$tagCount = 0
$tagById = [Collections.Generic.Dictionary[int,object]]::new()
foreach ($alignment in $alignments) {
    $wordCount += $alignment.Words.Count
    foreach ($boundary in $alignment.Boundaries) {
        $previous = if ($boundary.Index -gt 0) { $alignment.Words[$boundary.Index - 1] }
        $next = if ($boundary.Index -lt $alignment.Words.Count) { $alignment.Words[$boundary.Index] }
        if (![object]::ReferenceEquals($boundary.Previous, $previous) -or ![object]::ReferenceEquals($boundary.Next, $next)) {
            throw 'An alignment boundary lost its adjacent word.'
        }
        foreach ($tag in $boundary.Tags) {
            $tagCount++
            if (!$tagById.ContainsKey($tag.Id)) { $tagById.Add($tag.Id, $tag) }
            if (![object]::ReferenceEquals($tagById[$tag.Id], $tag)) { throw 'Repeated tags lost identity.' }
        }
    }
}
if ($alignments.Count -ne 7 -or $wordCount -ne 439 -or $tagCount -ne 23 -or $tagById.Count -ge $tagCount -or
    $gaps.Count -ne 936 -or @($gaps | Where-Object Internal).Count -ne 933) {
    throw 'Acoustic or alignment counts differ from the checkpoint.'
}

$privateMarkers = '(?i)[a-z]:[\\/]|\.wav\b|\.mp3\b|[0-9a-f]{64}'
if ([Text.Encoding]::ASCII.GetString($bytes) -match $privateMarkers -or
    [Text.Encoding]::Unicode.GetString($bytes) -match $privateMarkers -or
    [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1) -match $privateMarkers) {
    throw 'Unexpected private source marker in the compiled seed.'
}
[pscustomobject]@{
    Assembly = $path
    SHA256 = (Get-FileHash -LiteralPath $path).Hash
    Percepts = $seed.Percepts.Count
    Evidence = $seed.Evidence.Count
    WordSpans = $wordCount
    TagOccurrences = $tagCount
    Gaps = $gaps.Count
    SharedReferencesVerified = $true
}
