#requires -Version 7.7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ImagePath,
    [Parameter(Mandatory)][string] $PscPath,
    [Parameter(Mandatory)][string] $OutputPath
)
$ErrorActionPreference = 'Stop'
$imageFile = (Resolve-Path -LiteralPath $ImagePath).Path
$compiler = (Resolve-Path -LiteralPath $PscPath).Path
$output = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($output) -ne '.dll') { throw 'The output must be a DLL.' }
$types = Join-Path $PSScriptRoot 'PerceptSeed.ps1'
. $types
$null = . "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition
$image = & $studentOwner { param($file) Open-StudentImage $file } $imageFile

# Read only the reviewed measurement fields. Names used to join private rows never enter the graph.
function Get-OptionalNumber($value) {
    if ($null -eq $value) { return }
    if ($value -is [pscustomobject] -and !@($value.PSObject.Properties).Count) { return }
    [double]$value
}

$prompts = [Collections.Generic.Dictionary[string,StudentSeedPrompt]]::new([StringComparer]::Ordinal)
$tags = [Collections.Generic.Dictionary[string,StudentSeedTag]]::new([StringComparer]::Ordinal)
function Get-Prompt([string]$lead) {
    if (!$prompts.ContainsKey($lead)) { $prompts.Add($lead, [StudentSeedPrompt]@{ Id = $prompts.Count + 1 }) }
    $prompts[$lead]
}
function Get-Tag([string]$name) {
    if (!$tags.ContainsKey($name)) { $tags.Add($name, [StudentSeedTag]@{ Id = $tags.Count + 1 }) }
    $tags[$name]
}
function Read-TransferRows($rows) {
    foreach ($row in $rows) {
        [StudentSeedTransferRow]@{ Prompt = Get-Prompt $row.Lead; DeltaMs = $row.DeltaMs }
    }
}
function Read-Acoustics($value) {
    [StudentSeedAcoustics]@{
        MedianF0Hz = Get-OptionalNumber $value.MedianF0Hz
        FrameHop = $value.FrameHop
        AnalysisRate = $value.AnalysisRate
        Gaps = @(foreach ($gap in $value.Gaps) {
            [StudentSeedGap]@{
                FirstFrame = $gap.FirstFrame; Frames = $gap.Frames; Seconds = $gap.Seconds; Internal = $gap.Internal
                PreGapSlopeSemitonesPerSecond = Get-OptionalNumber $gap.PreGapSlopeSemitonesPerSecond
                PitchResetSemitones = Get-OptionalNumber $gap.PitchResetSemitones
            }
        })
    }
}
function Read-Alignment($value) {
    $words = @(foreach ($word in $value.Words) {
        [StudentSeedWord]@{
            StartMs = $word.StartMs; EndMs = $word.EndMs; StartShiftMs = $word.StartShiftMs; EndShiftMs = $word.EndShiftMs
            MedianF0Hz = Get-OptionalNumber $word.MedianF0Hz
        }
    })
    [StudentSeedAlignment]@{
        DurationSeconds = $value.DurationSeconds
        Words = $words
        Boundaries = @(foreach ($boundary in $value.Boundaries) {
            $index = [int]$boundary.Index
            if ($index -lt 0 -or $index -gt $words.Count) { throw 'Invalid word boundary index.' }
            [StudentSeedBoundary]@{
                Index = $index
                Previous = if ($index -gt 0) { $words[$index - 1] }
                Next = if ($index -lt $words.Count) { $words[$index] }
                Tags = @(foreach ($tag in $boundary.Tags) { if ($tag) { Get-Tag $tag } })
                Mark = if ($boundary.Mark -cin ',', ':', '.', '?', '!', ';') { $boundary.Mark }
                QuietRmsMs = Get-OptionalNumber $boundary.QuietRmsMs
                PitchChangeSemitones = Get-OptionalNumber $boundary.PitchChangeSemitones
                WarpShiftMs = $boundary.WarpShiftMs
                CollapsedNeighbor = $boundary.CollapsedNeighbor
            }
        })
    }
}

$ids = 'Occurrence', 'Word', 'Boundary', 'Timing.Zira.WordOnset', 'Timing.Kokoro.MarkFrames',
    'Performance.Generated.Acoustics', 'Performance.Generated.HeartReading.Alignment'
$nodes = [Collections.Generic.Dictionary[string,StudentSeedPercept]]::new([StringComparer]::Ordinal)
$evidence = [Collections.Generic.List[StudentSeedObservation]]::new()
foreach ($id in $ids) {
    if (!$image.Percepts.ContainsKey($id)) { throw "Missing percept in input image: $id" }
    $node = $image.Percepts[$id]
    $examples = @(for ($i = 0; $i -lt $node.Examples.Count; $i++) {
        $record = $node.Examples[$i]
        $observation = [StudentSeedObservation]@{ Identity = "seed/$id/$($i + 1)" }
        $value = $record.Measured
        switch -Exact ($id) {
            'Timing.Zira.WordOnset' {
                if ($record.Condition -ceq 'HeldOutWordOnsetDeltaMilliseconds') {
                    $observation.Condition = 'Held-out onset delta'
                    $observation.Transfer = [StudentSeedTransfer]@{
                        AddedFrames = $value.AddedFrames; HeldOutMAEms = $value.HeldOutMAEms
                        ZeroEffectMAEms = $value.ZeroEffectMAEms; Samples = $value.Samples
                        Fit = @(Read-TransferRows $value.Fit); Test = @(Read-TransferRows $value.Test)
                    }
                    break
                }
                $observation.Condition = 'Word onset'
                $observation.OnsetMilliseconds = [double]$value
            }
            'Timing.Kokoro.MarkFrames' {
                if ($record.Condition -cnotin 'Fit', 'Test') { throw 'Unknown clock split.' }
                $observation.Condition = $record.Condition
                $observation.Frames = [int]$value
            }
            'Performance.Generated.Acoustics' {
                $observation.Condition = 'Unaligned acoustic measurement'
                $observation.Acoustics = Read-Acoustics $value
            }
            'Performance.Generated.HeartReading.Alignment' {
                $observation.Condition = 'Unreviewed alignment'
                $observation.Alignment = Read-Alignment $value.Alignment
            }
            default { throw "No export projection for evidence on $id." }
        }
        if ($null -ne $observation.OnsetMilliseconds -or $null -ne $observation.Frames) {
            $markAt = $record.Occurrence.IndexOfAny([char[]]',:.')
            if ($markAt -le 0) { throw 'Clock evidence is missing its lead or punctuation.' }
            $observation.Prompt = Get-Prompt $record.Occurrence.Substring(0, $markAt)
            $observation.Mark = [string]$record.Occurrence[$markAt]
        }
        $evidence.Add($observation)
        $observation
    })
    $parent = if ($node.Parent) { $nodes[$node.Parent.Identity] }
    if ($node.Kind -cnotin 'Occurrence', 'Word', 'Boundary', 'TimingObservation', 'RecordingObservation') { throw 'Unknown percept kind.' }
    $nodes.Add($id, [StudentSeedPercept]@{ Identity = $id; Kind = $node.Kind; Key = $node.Key; Parent = $parent; Examples = $examples })
}
foreach ($id in $ids) {
    $node = $nodes[$id]
    $node.Children = @(foreach ($childId in $ids) {
        if ([object]::ReferenceEquals($nodes[$childId].Parent, $node)) { $nodes[$childId] }
    })
}
$graph = [StudentPerceptSeed]@{
    Occurrence = $nodes['Occurrence']
    Percepts = @(foreach ($id in $ids) { $nodes[$id] })
    Evidence = $evidence.ToArray()
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output))
& $compiler -Mode Compile -SourcePath $types -ClassName StudentPerceptSeed -StaticData @{
    'StudentPerceptSeed.Seed' = $graph
} -OutputPath $output -Deterministic
