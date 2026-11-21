using module ./StudentSourceInventory.psm1
#requires -Version 7.7
[CmdletBinding()]
param(
    [string] $InventoryPath = (Join-Path $PSScriptRoot '../data/source-bank/sources.bin'),
    [string] $EvidenceDirectory = (Join-Path $PSScriptRoot '../data/source-bank/linguistic'),
    [Parameter(Mandatory)][string] $PhonemizerReceipt,
    [string[]] $InterpretWork = @('pg11','pg30036'),
    [switch] $InterpretAll
)
$ErrorActionPreference = 'Stop'
$sourceBank = Open-StudentSourceInventory $InventoryPath
$destination = [IO.Directory]::CreateDirectory($EvidenceDirectory).FullName
$clock = [Diagnostics.Stopwatch]::StartNew()
$null = . "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition
& $studentOwner {
    param($bank,$destination,$receipt,$clock,$interpretNames,$interpretAll)
    if ($receipt) {
        $receipt = Get-Item -LiteralPath $receipt
        $pin = Import-PowerShellDataFile -LiteralPath $receipt.FullName
        $script:StudentInputs.Phonemizer = @{
            Directory = [IO.Path]::GetRelativePath($script:StudentRoot,$receipt.DirectoryName)
            SHA256 = $pin.AssemblySha256
        }
    }
    $driver = Import-StudentPhonemizer
    $kernels = Import-StudentKernels
    $works = [Collections.Generic.Dictionary[string,StudentSourceUnit]]::new([StringComparer]::Ordinal)
    foreach ($source in $bank.Units.Values) {
        if ($source.Kind -cne 'FullText' -or $source.EvidenceGroup -cnotmatch '^Gutenberg/([0-9]+)$') { continue }
        $name = "pg$($Matches[1])"
        if ($works.ContainsKey($name)) { throw "Multiple retained editions of $name require edition selection." }
        if ((Get-FileHash -LiteralPath $source.Path).Hash -cne $source.Checksum) { throw "Source checksum mismatch for $name." }
        $works.Add($name,$source)
    }
    foreach ($name in $interpretNames) {
        if (!$works.ContainsKey($name)) { throw "No retained source for requested interpretation of $name." }
    }
    $script:StudentInputs.HumanText = [IO.Path]::GetRelativePath($script:StudentRoot,$works['pg11'].Path)
    $script:StudentInputs.Text = [IO.Path]::GetRelativePath($script:StudentRoot,[IO.Path]::GetDirectoryName($works['pg11'].Path))
    $alice = @(Get-StudentBooks 'pg11')[0]
    $original = $alice.Source.OriginalText
    $opening = $original.IndexOf('Alice was beginning to get very tired',[StringComparison]::Ordinal)
    $openingSpan = @($bank.Units.Values.Where({$_.Kind -ceq 'TextSpanUtf16' -and $_.Start -eq $opening -and $_.Parent.EvidenceGroup -ceq 'Gutenberg/11'}))
    $openingIssues = @()
    if ($openingSpan.Count -eq 1) {
        $sample = $original.Substring($opening,$openingSpan[0].Length)
        $probe = $driver.Invoke($sample)
        $openingIssues = @($probe.Tokens | Where-Object Status -CNE Valid)
        "Opening paragraph raw input: complete=$($probe.Complete), pronunciation=$($probe.PronunciationStatus), grammar=$($probe.GrammarStatus)"
        foreach ($token in $probe.Tokens) {
            if ($token.Status -cne 'Valid') { "  UTF16 $($opening + $token.SourceStart): '$($token.Word)' status=$($token.Status) alternatives=$($token.Alternatives -join ',')" }
        }
    }
    foreach ($name in $works.Keys | Sort-Object) {
        $work = $works[$name]
        $script:StudentInputs.Text = [IO.Path]::GetRelativePath($script:StudentRoot,[IO.Path]::GetDirectoryName($work.Path))
        $book = if ($name -ceq 'pg11') {$alice} else {@(Get-StudentBooks $name)[0]}
        if (!$book.CollectionComplete) { throw "Incomplete corpus traversal for $name" }
        $target = Join-Path $destination "$name.bin"
        $temp = "$target.$([guid]::NewGuid()).partial"
        $sentenceCount = $book.Sentences.Length / 2
        $failed = 0
        $words = 0
        for ($i=0; $i -lt $book.Tokens.Length; $i+=4) { if ($book.Tokens[$i] -eq 1) {$words++} }
        try {
            $w = [IO.BinaryWriter]::new([IO.File]::Open($temp,[IO.FileMode]::CreateNew))
            try {
                $w.Write('StudentTextEvidence/2')
                $w.Write($work.Id)
                $w.Write($script:StudentInputs.Phonemizer.SHA256)
                $w.Write($kernels.SHA256)
                if ($name -ceq 'pg11') {
                    $w.Write([int]$openingIssues.Count)
                    foreach ($issue in $openingIssues) {
                        $w.Write([int]($opening+$issue.SourceStart))
                        $w.Write([int]($issue.SourceEnd-$issue.SourceStart))
                        $w.Write([string]$issue.Status)
                    }
                } else { $w.Write([int]0) }
                foreach ($field in 'Tokens','OriginalSpans','Paragraphs','Sentences','Headings','CounterExample') {
                    $values = $book.$field
                    $w.Write([int]$values.Length)
                    $bytes = [byte[]]::new([Buffer]::ByteLength($values))
                    [Buffer]::BlockCopy($values,0,$bytes,0,$bytes.Length)
                    $w.Write($bytes)
                }
                $interpretations = if ($interpretAll -or $name -cin $interpretNames) {[int]$sentenceCount} else {0}
                $w.Write([int]$interpretations)
                $chars = $book.Text.ToCharArray()
                for ($s = 0; $s -lt $interpretations; $s++) {
                    $first = $book.Sentences[2*$s]
                    $last = $book.Sentences[2*$s+1]
                    $spans = [int[]]::new(2*($last-$first+1))
                    $projected = $kernels.Project.Invoke($book.Tokens,$chars,$first,$last,$spans)
                    $failure = ''
                    $result = $null
                    if ($projected) {
                        try { $result = $driver.Invoke($projected) } catch { $failure = $_.Exception.GetBaseException().Message }
                    } else { $failure = 'Corpus projection supplied no pronounceable input.' }
                    if ($result -and !$result.Complete) { $failure = 'Compiled pronunciation incomplete.' }
                    if ($failure) { $failed++ }
                    if ($result) {
                        $w.Write([string]($result.GrammarStatus ?? 'Unavailable'))
                        $w.Write([string]($result.PronunciationStatus ?? 'Unavailable'))
                    } else {
                        $w.Write('Unavailable')
                        $w.Write('Unavailable')
                    }
                    $w.Write([string]($failure ?? ''))
                    $phones = if ($result) { $result.KokoroPhones }
                    $w.Write([string]($phones ?? ''))
                    $tokens = @(if ($result) { $result.Tokens | Where-Object { $null -ne $_ } })
                    $events = [int[]]::new(2*$tokens.Count)
                    for ($t=0;$t -lt $tokens.Count;$t++) {
                        $events[2*$t] = $tokens[$t].SourceStart
                        $events[2*$t+1] = $tokens[$t].SourceEnd-$tokens[$t].SourceStart
                    }
                    $covered = $kernels.Cover.Invoke($spans,$events)
                    $w.Write([int]$covered.Length)
                    foreach ($entry in $covered) { $w.Write([int]($entry + $(if($entry -ge 0){$first}else{0}))) }
                    foreach ($property in 'Pron','PronunciationSource','Status') {
                        $w.Write([int]$tokens.Count)
                        foreach ($token in $tokens) { $w.Write([string]($token.$property ?? '')) }
                    }
                    foreach ($token in $tokens) {
                        $roles = @($token.Roles | Where-Object { $null -ne $_ })
                        $w.Write([int]$roles.Count)
                        foreach ($role in $roles) { $w.Write([int]$role) }
                        $alternatives = @($token.Alternatives | Where-Object { $null -ne $_ })
                        $w.Write([int]$alternatives.Count)
                        foreach ($reading in $alternatives) { $w.Write([string]$reading) }
                    }
                    $morphs = [Collections.Generic.List[ValueTuple[int,object]]]::new()
                    for ($t=0;$t -lt $tokens.Count;$t++) {
                        foreach ($parse in $tokens[$t].Morphology) { $morphs.Add([ValueTuple[int,object]]::new($t,$parse)) }
                    }
                    $w.Write($morphs.Count)
                    foreach ($pair in $morphs) {
                        $w.Write($pair.Item1)
                        $morph = $pair.Item2
                        $w.Write([int]$morph.Role)
                        $w.Write([int]$morph.RootLexicalId)
                        $w.Write([string]$morph.Root)
                        $w.Write([string]$morph.Phones)
                        $rules = @(for ($node=$morph; $node -and $node.Rule; $node=$node.Inner) {$node.Rule.Name})
                        $w.Write([int]$rules.Count)
                        foreach ($rule in $rules) { $w.Write([string]$rule) }
                    }
                    $proposals = @(if ($result) { $result.Proposals | Where-Object {$null -ne $_} })
                    $clauses = @(if ($result) { $result.Clauses | Where-Object {$null -ne $_} })
                    $candidates = [Collections.Generic.List[ValueTuple[string,int[]]]]::new()
                    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    foreach ($clause in $clauses) {
                        foreach ($candidate in $clause.Candidates) {
                            $links = [int[]]@(
                                $clause.First
                                $clause.Last
                                if ($candidate.Subject -and $candidate.Subject.Head) { $candidate.Subject.Head.Identity } else {-1}
                                if ($candidate.Predicate) { $candidate.Predicate.Identity } else {-1}
                                if ($candidate.Object -and $candidate.Object.Head) { $candidate.Object.Head.Identity } else {-1}
                                if ($candidate.Auxiliary) { $candidate.Auxiliary.Identity } else {-1}
                                if ($candidate.Relation) { $candidate.Relation.Identity } else {-1}
                            )
                            $kind = "ClauseCandidate/$($candidate.Status)/$($candidate.Voice)/$($candidate.Tense)"
                            if ($seen.Add("$kind/$($links -join ',')")) {
                                $candidates.Add([ValueTuple[string,int[]]]::new($kind,$links))
                            }
                        }
                    }
                    $w.Write([int]($proposals.Count+$clauses.Count+$candidates.Count))
                    foreach ($clause in $clauses) {
                        $w.Write('ClauseSpan')
                        $w.Write([int]0)
                        $w.Write([int]$clause.Candidates.Count)
                        $w.Write([int]2)
                        $w.Write([int]$clause.First)
                        $w.Write([int]$clause.Last)
                    }
                    foreach ($proposal in $proposals) {
                        $w.Write([string]$proposal.Kind)
                        $w.Write([int]$proposal.Support)
                        $w.Write([int]$proposal.Viable)
                        $links = @($proposal.Owner,$proposal.Anchor,$proposal.Scope,$proposal.ScopeEnd) + @($proposal.Dependencies)
                        $w.Write([int]$links.Count)
                        foreach ($link in $links) { $w.Write([int]$link) }
                    }
                    foreach ($candidate in $candidates) {
                        $w.Write($candidate.Item1)
                        $w.Write([int]0)
                        $w.Write([int]0)
                        $w.Write([int]$candidate.Item2.Length)
                        foreach ($link in $candidate.Item2) { $w.Write($link) }
                    }
                }
            } finally { $w.Dispose() }
            [IO.File]::Move($temp,$target,$true)
        } finally { [IO.File]::Delete($temp) }
        "$name words=$words tokens=$($book.Tokens.Length / 4) sentences=$sentenceCount interpreted=$interpretations unresolved=$failed bytes=$((Get-Item -LiteralPath $target).Length) elapsed=$($clock.Elapsed.TotalSeconds)"
    }
} $sourceBank $destination $PhonemizerReceipt $clock $InterpretWork $InterpretAll
