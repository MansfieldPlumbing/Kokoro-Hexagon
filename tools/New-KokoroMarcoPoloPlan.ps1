#requires -Version 7.4
# Build a deterministic phoneme-to-PCM device test plan from admitted phrases.
# This is compiler/test input. It does not execute model arithmetic or speech.
[CmdletBinding()]
param(
    [ValidateRange(1, 200)][int]$Cases = 24,
    [ValidateRange(1, 510)][int]$MaxPhonemes = 510,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../build/marco-polo')
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = [IO.Path]::GetFullPath((Join-Path $repo 'build'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $output.StartsWith($build + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The plan output must be inside the repository build directory.'
}
$corpusPath = Join-Path $repo 'bench/corpus.json'
$corpusBytes = [IO.File]::ReadAllBytes($corpusPath)
$corpusHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($corpusBytes))
$corpus = @([Text.Encoding]::UTF8.GetString($corpusBytes) | ConvertFrom-Json)
if ($corpus.Count -lt 4) { throw 'The pinned corpus needs at least four phrases.' }
$knownIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$admission = & (Join-Path $repo 'src/text/Kokoro.PhonemeExpression.ps1') -RepositoryRoot $repo
$contract = & $admission.Verify
if (-not $contract.Passed) { throw 'The pinned phoneme contract failed.' }
$toIds = (& $admission.BuildIds).Compile()
foreach ($item in $corpus) {
    if ($item.id -notmatch '^[a-z][a-z0-9_-]{0,31}$' -or
        -not $knownIds.Add([string]$item.id) -or
        [string]::IsNullOrWhiteSpace([string]$item.text) -or
        [string]::IsNullOrWhiteSpace([string]$item.phonemes) -or
        $item.voice -notmatch '^[a-z][a-z0-9_]{0,63}$') {
        throw 'The phrase corpus has an invalid identity or field.'
    }
    [void]$toIds.Invoke([string]$item.phonemes)
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$plans = [Collections.Generic.List[object]]::new()
function Add-Case {
    param([object[]]$Entries, [int]$Number)
    $voice = [string]$Entries[0].voice
    if (@($Entries | Where-Object voice -cne $voice).Count) {
        throw 'A device case cannot mix voice assets.'
    }
    $phonemes = ($Entries | ForEach-Object { [string]$_.phonemes }) -join ' '
    if ($phonemes.Length -gt $MaxPhonemes -or -not $seen.Add($phonemes)) { return $false }
    $tokenIds = [int[]]$toIds.Invoke($phonemes)
    if ($tokenIds.Length -ne $phonemes.Length + 2 -or
        $tokenIds[0] -ne 0 -or $tokenIds[-1] -ne 0) {
        throw 'Compiled phoneme admission returned an invalid boundary.'
    }
    $spans = [Collections.Generic.List[object]]::new()
    $cursor = 0
    foreach ($entry in $Entries) {
        $length = ([string]$entry.phonemes).Length
        $spans.Add([pscustomobject]@{
            CorpusId = [string]$entry.id
            PhonemeStart = $cursor
            PhonemeLength = $length
        })
        $cursor += $length + 1
    }
    $plans.Add([pscustomobject]@{
        Schema = 1
        CaseId = 'marco-{0:d3}' -f $Number
        SourceIds = [string[]]@($Entries | ForEach-Object { [string]$_.id })
        Text = ($Entries | ForEach-Object { [string]$_.text }) -join ' '
        Phonemes = $phonemes
        PhonemeIds = $tokenIds
        PhonemeCount = $phonemes.Length
        Voice = $voice
        VoiceRow = $phonemes.Length - 1
        Spans = $spans.ToArray()
        ExpectedSampleRate = 24000
        ReferenceStatus = 'requires_same_input_stock_reference'
    })
    $true
}

for ($index = 0; $index -lt [Math]::Min($Cases, $corpus.Count); $index++) {
    if (-not (Add-Case @($corpus[$index]) ($plans.Count + 1))) {
        throw 'A source phrase could not be admitted.'
    }
}
$groups = [ordered]@{
    '2' = [Collections.Generic.List[object]]::new()
    '3' = [Collections.Generic.List[object]]::new()
    '4' = [Collections.Generic.List[object]]::new()
}
for ($a = 0; $a -lt $corpus.Count; $a++) {
    for ($b = $a + 1; $b -lt $corpus.Count; $b++) {
        $groups['2'].Add([object[]]@($corpus[$a], $corpus[$b]))
        for ($c = $b + 1; $c -lt $corpus.Count; $c++) {
            $groups['3'].Add([object[]]@($corpus[$a], $corpus[$b], $corpus[$c]))
            for ($d = $c + 1; $d -lt $corpus.Count; $d++) {
                $groups['4'].Add([object[]]@($corpus[$a], $corpus[$b], $corpus[$c], $corpus[$d]))
            }
        }
    }
}
$next = @{ '2' = 0; '3' = 0; '4' = 0 }
while ($plans.Count -lt $Cases) {
    $before = $plans.Count
    foreach ($size in @('2', '3', '4')) {
        while ($next[$size] -lt $groups[$size].Count) {
            $entries = [object[]]$groups[$size][$next[$size]]
            $next[$size]++
            if (Add-Case $entries ($plans.Count + 1)) { break }
        }
        if ($plans.Count -ge $Cases) { break }
    }
    if ($plans.Count -eq $before) {
        throw 'The corpus cannot fill the requested cases within the phoneme limit.'
    }
}

[void][IO.Directory]::CreateDirectory($output)
$name = 'marco-polo-cases-{0}-limit-{1}-patience-3.json' -f $Cases, $MaxPhonemes
$path = Join-Path $output $name
$plan = [ordered]@{
    Schema = 1
    Source = 'bench/corpus.json'
    SourceSHA256 = $corpusHash
    VocabularySHA256 = $contract.SourceSHA256
    Order = 'corpus_then_round_robin_2_3_4_phrase_combinations'
    SearchPolicy = [ordered]@{
        WorseTrialPatience = 3
        WorseTrialDefinition = 'strictly_higher_same_input_objective_than_current_best'
        OnImprovement = 'save_best_and_reset_worse_trial_count'
        OnThirdConsecutiveWorseTrial = 'restore_best_and_halve_named_mutation_step'
        Promotion = 'best_verified_candidate_only'
    }
    CaseCount = $plans.Count
    MaxPhonemes = $MaxPhonemes
    Cases = $plans.ToArray()
}
$json = $plan | ConvertTo-Json -Depth 8
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
if (Test-Path -LiteralPath $path) {
    $existing = [IO.File]::ReadAllBytes($path)
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($existing, $bytes)) {
        throw 'The existing plan differs. Choose another output directory.'
    }
} else {
    [IO.File]::WriteAllBytes($path, $bytes)
}
$lengths = @($plans | ForEach-Object PhonemeCount | Sort-Object)
[pscustomobject]@{
    Path = $path
    Cases = $plans.Count
    ShortestPhonemes = $lengths[0]
    LongestPhonemes = $lengths[-1]
    SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
}
