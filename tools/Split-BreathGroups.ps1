#requires -Version 7.4
# Breath groups from a phoneme string, using SMA's own tokenizer.
#
# The phoneme stream is not PowerShell, but it does not need to be: the tokenizer splits on
# the same punctuation that delimits prosody, tolerates the parse errors that result, and
# hands back exact character offsets. Token kind carries boundary strength - Comma and Semi
# are intonational-phrase boundaries, while terminal punctuation lands as Generic.
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)][string] $Phonemes,
    [int] $MaxFrames = 0,          # optional cap; 0 leaves groups at their prosodic length
    [double] $FramesPerChar = 1.0  # crude length estimate until the duration predictor is on device
)
$ErrorActionPreference = 'Stop'

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($Phonemes, [ref]$tokens, [ref]$errors)

$major = 'Generic'                       # terminal punctuation: . ? ! and dashes
$minor = @('Comma', 'Semi', 'Colon')     # intonational-phrase boundaries

$groups = [Collections.Generic.List[object]]::new()
[int]$start = 0
[string]$pending = 'none'
foreach ($tok in $tokens) {
    if ($tok.Kind -eq 'EndOfInput') { break }
    [bool]$isMajor = ($tok.Kind -eq $major)
    [bool]$isMinor = ($minor -contains [string]$tok.Kind)
    if (-not ($isMajor -or $isMinor)) { continue }
    [int]$end = $tok.Extent.EndOffset
    $text = $Phonemes.Substring($start, $end - $start).Trim()
    if ($text) {
        $groups.Add([pscustomobject]@{
            Start = $start; End = $end; Text = $text
            Boundary = if ($isMajor) { 'breath' } else { 'phrase' }
            EstFrames = [int][Math]::Ceiling($text.Length * $FramesPerChar)
        })
    }
    $start = $end
    $pending = if ($isMajor) { 'breath' } else { 'phrase' }
}
if ($start -lt $Phonemes.Length) {
    $text = $Phonemes.Substring($start).Trim()
    if ($text) {
        $groups.Add([pscustomobject]@{
            Start = $start; End = $Phonemes.Length; Text = $text
            Boundary = 'end'; EstFrames = [int][Math]::Ceiling($text.Length * $FramesPerChar)
        })
    }
}
if ($groups.Count -eq 0) {
    $groups.Add([pscustomobject]@{ Start = 0; End = $Phonemes.Length; Text = $Phonemes.Trim(); Boundary = 'end'; EstFrames = [int][Math]::Ceiling($Phonemes.Length * $FramesPerChar) })
}

# A group longer than the cap gets split at its widest internal gap, so the cut still lands
# between words rather than inside one.
if ($MaxFrames -gt 0) {
    $split = [Collections.Generic.List[object]]::new()
    foreach ($g in $groups) {
        if ($g.EstFrames -le $MaxFrames) { $split.Add($g); continue }
        [int]$parts = [int][Math]::Ceiling($g.EstFrames / $MaxFrames)
        [int]$approx = [int][Math]::Ceiling($g.Text.Length / $parts)
        [int]$off = 0
        while ($off -lt $g.Text.Length) {
            [int]$take = [Math]::Min($approx, $g.Text.Length - $off)
            [int]$cut = $g.Text.LastIndexOf(' ', [Math]::Min($off + $take, $g.Text.Length - 1))
            if ($cut -le $off) { $cut = [Math]::Min($off + $take, $g.Text.Length) }
            $piece = $g.Text.Substring($off, $cut - $off).Trim()
            if ($piece) {
                $split.Add([pscustomobject]@{
                    Start = $g.Start + $off; End = $g.Start + $cut; Text = $piece
                    Boundary = if ($cut -ge $g.Text.Length) { $g.Boundary } else { 'split' }
                    EstFrames = [int][Math]::Ceiling($piece.Length * $FramesPerChar)
                })
            }
            $off = $cut + 1
        }
    }
    $groups = $split
}

$groups
