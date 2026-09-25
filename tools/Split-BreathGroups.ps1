#requires -Version 7.4
# Breath groups from a phoneme stream.
#
# Scans literal spans: phoneme runs, whitespace, and punctuation, each with exact character
# offsets. Boundary strength is a separate classifier keyed on the punctuation character
# itself, and is a hypothesis to be validated against measured duration - not something the
# scanner asserts.
#
# An earlier version used PowerShell's own tokenizer and read boundary strength off token
# kinds. That was wrong: Identifier and Generic are incidental classifications of an IPA
# stream under PowerShell's lexical rules, not a prosodic ontology, and they correlated only
# by accident on the strings it was tried against. Offsets are what a parser is good for;
# semantics have to be tested independently.
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)][string] $Phonemes,
    [int] $MaxFrames = 0,          # optional cap; 0 leaves groups at their prosodic length
    [double] $FramesPerChar = 1.0  # placeholder until the duration predictor runs on device
)
$ErrorActionPreference = 'Stop'
if ($MaxFrames -lt 0 -or -not [double]::IsFinite($FramesPerChar) -or $FramesPerChar -le 0) {
    throw 'Frame planning inputs must be finite and nonnegative, with positive frames per character.'
}

# Punctuation that carries a pause, with a provisional strength. These are hypotheses:
# 'breath' is a full stop, 'phrase' an intonational-phrase boundary. Validate against
# measured pause duration before treating either as ground truth.
$strength = @{
    '.' = 'breath'; '!' = 'breath'; '?' = 'breath'; '…' = 'breath'
    ';' = 'phrase'; ':' = 'phrase'; ',' = 'phrase'
    '—' = 'phrase'; '–' = 'phrase'
}

$spans = [Collections.Generic.List[object]]::new()
[int]$i = 0
[int]$n = $Phonemes.Length
while ($i -lt $n) {
    [char]$c = $Phonemes[$i]
    if ([char]::IsWhiteSpace($c)) {
        [int]$s = $i
        while ($i -lt $n -and [char]::IsWhiteSpace($Phonemes[$i])) { $i++ }
        $spans.Add([pscustomobject]@{ Kind = 'space'; Start = $s; End = $i; Text = $Phonemes.Substring($s, $i - $s); Strength = $null })
        continue
    }
    if ($strength.ContainsKey([string]$c)) {
        [int]$s = $i
        [string]$best = $strength[[string]$c]
        while ($i -lt $n -and $strength.ContainsKey([string]$Phonemes[$i])) {
            if ($strength[[string]$Phonemes[$i]] -eq 'breath') { $best = 'breath' }
            $i++
        }
        $spans.Add([pscustomobject]@{ Kind = 'pause'; Start = $s; End = $i; Text = $Phonemes.Substring($s, $i - $s); Strength = $best })
        continue
    }
    [int]$s = $i
    while ($i -lt $n -and -not [char]::IsWhiteSpace($Phonemes[$i]) -and -not $strength.ContainsKey([string]$Phonemes[$i])) { $i++ }
    $spans.Add([pscustomobject]@{ Kind = 'phonemes'; Start = $s; End = $i; Text = $Phonemes.Substring($s, $i - $s); Strength = $null })
}

# Groups run up to and including each pause span.
$groups = [Collections.Generic.List[object]]::new()
[int]$start = 0
[bool]$hasContent = $false
foreach ($sp in $spans) {
    if ($sp.Kind -eq 'phonemes') { $hasContent = $true; continue }
    if ($sp.Kind -ne 'pause') { continue }
    if (-not $hasContent) { continue }
    $text = $Phonemes.Substring($start, $sp.End - $start).Trim()
    $groups.Add([pscustomobject]@{
        Start = $start; End = $sp.End; Text = $text
        Boundary = $sp.Strength; Pause = $sp.Text
        EstFrames = [int][Math]::Ceiling($text.Length * $FramesPerChar)
    })
    $start = $sp.End
    $hasContent = $false
}
if ($hasContent) {
    $text = $Phonemes.Substring($start).Trim()
    if ($text) {
        $groups.Add([pscustomobject]@{
            Start = $start; End = $n; Text = $text
            Boundary = 'end'; Pause = ''
            EstFrames = [int][Math]::Ceiling($text.Length * $FramesPerChar)
        })
    }
}

# A group over the cap is split at a whitespace span, so a cut never lands inside a phoneme
# run. Spans already give the legal cut points.
if ($MaxFrames -gt 0) {
    $split = [Collections.Generic.List[object]]::new()
    foreach ($g in $groups) {
        if ($g.EstFrames -le $MaxFrames) { $split.Add($g); continue }
        $cuts = @($spans | Where-Object { $_.Kind -eq 'space' -and $_.Start -gt $g.Start -and $_.End -lt $g.End } | ForEach-Object { $_.Start })
        [int]$from = $g.Start
        [int]$budget = [int][Math]::Floor($MaxFrames / $FramesPerChar)
        if ($budget -lt 1) { throw 'The frame cap cannot admit one phoneme character.' }
        while ($from -lt $g.End) {
            [int]$limit = $from + $budget
            if ($limit -ge $g.End) { $limit = $g.End }
            else {
                $candidate = @($cuts | Where-Object { $_ -gt $from -and $_ -le $limit })
                if ($candidate.Count) { $limit = $candidate[-1] }
                else { throw "No legal whitespace boundary fits the frame cap in group at offset $($g.Start)." }
            }
            $piece = $Phonemes.Substring($from, $limit - $from).Trim()
            if ($piece) {
                $split.Add([pscustomobject]@{
                    Start = $from; End = $limit; Text = $piece
                    Boundary = if ($limit -ge $g.End) { $g.Boundary } else { 'split' }
                    Pause = if ($limit -ge $g.End) { $g.Pause } else { '' }
                    EstFrames = [int][Math]::Ceiling($piece.Length * $FramesPerChar)
                })
            }
            $from = $limit
            while ($from -lt $g.End -and [char]::IsWhiteSpace($Phonemes[$from])) { $from++ }
        }
    }
    $groups = $split
}

$groups
