<#
.SYNOPSIS
    Independent judges of the Student's front end: scores only, from the pinned phonemizer the Student uses.

.DESCRIPTION
    The judges are owned apart from student/Invoke-Student.ps1 so the measures are not shaped by the work they
    score. Each judge returns a typed score object and writes a receipt under build/. Probe items are generated
    from the lexicon and the corpus by declared records, never from hand-picked words or sentences.

      Composition       Leave-whole-word-out: every lexicon form the authored morphology derives from a different
                        root, scored against the lexicon's pronunciation of the whole form.
      CompositionRecall Lexicon forms that are a standard English affix on a lexicon stem (with standard spelling
                        restoration): the share the authored morphology parses at all.
      CorpusCoverage    Corpus paragraphs at a fixed stride through the phonemizer, best effort: the share of word
                        tokens spoken and from which source, complete paragraphs, grammar status, and the word tokens
                        that carry a grammatical role clause composition can consume.
      Phonics           Lexicon forms at a fixed stride sounded out with their own entry withheld, scored against it.
      Phrasing          Corpus paragraphs with the author's punctuation removed; the breaks the reader restores between
                        words, scored for place and strength (komma, kolon, periodos) against the author's marks.
      All               Every judge above.
      Ratchet           Every judge, compared with the declared baseline; throws if any measure regresses.
#>
param(
    [ValidateSet('Composition', 'CompositionRecall', 'CorpusCoverage', 'Phonics', 'Phrasing', 'All', 'Ratchet')][string] $Step = 'All',
    [ValidateRange(1, [int]::MaxValue)][int] $ParagraphStride = 97
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:JudgeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:JudgeSHA256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$script:JudgeContext = [ordered]@{ Run = $null; Compose = $null; Lexicon = $null; DriverSHA256 = $null; Text = $null; OutputDirectory = $null }

# Standard English affixes. Suffix stems are restored by the spelling rules in Get-JudgeStems: the bare remainder,
# a dropped final e, y written as i before the affix, and an undoubled final consonant.
$script:JudgeAffixes = [ordered]@{
    Suffix = @('ies', 'es', 's', 'ied', 'ed', 'ing', 'ier', 'iest', 'er', 'est', 'ily', 'ly', 'iness', 'ness', 'less', 'ful',
        'able', 'ible', 'ment', 'ity', 'ation', 'ize', 'ise', 'ish', 'ive', 'ous', 'al', 'ism', 'ist', 'ship', 'hood', 'ward', 'wise')
    Prefix = @('re', 'un', 'dis', 'pre', 'mis', 'non', 'over', 'under', 'out', 'sub', 'inter', 'anti', 'semi', 'co', 'de', 'in', 'im', 'post')
}
$script:JudgeLimits = [ordered]@{ MinimumWord = 3; MinimumRecallWord = 5; MinimumStem = 3; LexiconRoles = 4
    ParagraphMinimum = 40; ParagraphMaximum = 2000; Examples = 3; PhonicsStride = 23 }

function Get-JudgeStudentPin {
    # The phonemizer the Student pins, read from its declared inputs record without running the Student.
    $path = Join-Path $script:JudgeRoot 'student/Invoke-Student.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:StudentInputs' }, $true)
    if ($null -eq $assignment) { throw "No `$script:StudentInputs record in $path." }
    $record = @{}
    foreach ($pair in $assignment.Right.Find({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs) {
        if ($pair.Item1.Value -cne 'Phonemizer') { continue }
        foreach ($field in $pair.Item2.Find({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs) {
            $record[$field.Item1.Value] = $field.Item2.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true).Value
        }
    }
    foreach ($pair in $assignment.Right.Find({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs) {
        if ($pair.Item1.Value -ceq 'Text') { $record.Text = $pair.Item2.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true).Value }
    }
    if (-not $record.Directory -or -not $record.SHA256 -or -not $record.Text) { throw 'The Student inputs record has no phonemizer Directory, SHA256 or Text.' }
    $record
}

function Import-JudgePhonemizer {
    if ($null -ne $script:JudgeContext.Run) { return }
    $pin = Get-JudgeStudentPin
    $directory = Join-Path $script:JudgeRoot $pin.Directory
    $receiptPath = Join-Path $directory 'driver-receipt.psd1'
    if (-not (Test-Path -LiteralPath $receiptPath)) { throw "The pinned phonemizer driver is not built: $directory. Build it with phonemizer/Invoke-EnglishPhonemizer.ps1." }
    $receipt = Import-PowerShellDataFile $receiptPath
    $path = Join-Path $directory ([IO.Path]::GetFileName($receipt.Output))
    if ((Get-FileHash -LiteralPath $path).Hash -cne $pin.SHA256) { throw 'Pinned phonemizer integrity mismatch.' }
    $assembly = [Reflection.Assembly]::LoadFrom($path)
    $driver = $assembly.GetType('CoreDriver', $true)
    $composition = $driver.GetMethod('WordCompositions')
    if ($null -eq $composition) { throw 'The pinned phonemizer has no compiled morphology inventory.' }
    $script:JudgeContext.Run = $driver.GetMethod('Run').CreateDelegate([Func[string,object]])
    $script:JudgeContext.Compose = $composition.CreateDelegate([Func[string,object]])
    $script:JudgeContext.Lexicon = $assembly.GetType('Lexicon', $true)
    $script:JudgeContext.DriverSHA256 = $pin.SHA256
    $script:JudgeContext.Text = Join-Path $script:JudgeRoot $pin.Text
}

function Get-JudgeOutputDirectory {
    if ($null -eq $script:JudgeContext.OutputDirectory) {
        $directory = Join-Path $script:JudgeRoot ('build/student-judges-{0:yyyyMMddTHHmmss}' -f [DateTime]::UtcNow)
        [void][IO.Directory]::CreateDirectory($directory); $script:JudgeContext.OutputDirectory = $directory
    }
    $script:JudgeContext.OutputDirectory
}

function New-JudgeScore([string] $Judge, [object] $Strata, [object] $Totals, [string] $Boundary) {
    $score = [pscustomobject]@{ PSTypeName = 'Kokoro.StudentJudgeScore'; Judge = $Judge; Totals = $Totals; Strata = $Strata
        DriverSHA256 = $script:JudgeContext.DriverSHA256; JudgeSHA256 = $script:JudgeSHA256
        PowerShell = $PSVersionTable.PSVersion.ToString(); Runtime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        Boundary = $Boundary; Receipt = $null }
    $score.Receipt = Join-Path (Get-JudgeOutputDirectory) "$Judge.clixml"
    Export-Clixml -LiteralPath $score.Receipt -InputObject $score -Depth 6
    $score
}

function Get-JudgeLexiconReadings([int] $Id) {
    $readings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($role in 0..$script:JudgeLimits.LexiconRoles) { $phones = $script:JudgeContext.Lexicon::Phones($Id, $role); if ($phones) { [void]$readings.Add($phones) } }
    , $readings
}

function Get-JudgeSegments([string] $Phones) { $Phones.Replace('ˈ', '').Replace('ˌ', '') }

function Get-JudgeRuleChain($Parse) {
    $names = [Collections.Generic.List[string]]::new(); $cursor = $Parse
    while ($null -ne $cursor.Rule) { $names.Add($cursor.Rule.Name); $cursor = $cursor.Inner }
    $names -join '+'
}

function Get-JudgeShare([int] $Count, [int] $Total) { if ($Total) { [Math]::Round(100.0 * $Count / $Total, 1) } else { [double]::NaN } }

function Measure-JudgeComposition {
    # Odd lexical ids are held out: anything that tunes composition from lexicon evidence learns from even ids only,
    # and HeldOutExactPercent scores the odd ids.
    Import-JudgePhonemizer
    $lexicon = $script:JudgeContext.Lexicon; $rows = [Collections.Generic.List[object]]::new()
    for ($id = 0; $id -lt $lexicon::Count(); $id++) {
        $word = $lexicon::Form($id)
        if ($word.Length -lt $script:JudgeLimits.MinimumWord -or $word -cnotmatch '^[a-z]+$') { continue }
        $parses = @($script:JudgeContext.Compose.Invoke($word) | Where-Object { $_.Root -cne $word })
        if (-not $parses.Count) { continue }
        $reference = Get-JudgeLexiconReadings $id
        $segments = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($phones in $reference) { [void]$segments.Add((Get-JudgeSegments $phones)) }
        $readings = @($parses | ForEach-Object Phones | Sort-Object -Unique)
        $exact = @($readings | Where-Object { $reference.Contains($_) }).Count
        $chains = @($parses | ForEach-Object { Get-JudgeRuleChain $_ } | Sort-Object -Unique)
        $rows.Add([pscustomobject]@{ Id = $id; Word = $word; Chain = $chains[0]; Readings = $readings -join '|'; Reference = @($reference) -join '|'
            Exact = $exact -gt 0; Segments = @($readings | Where-Object { $segments.Contains((Get-JudgeSegments $_)) }).Count -gt 0
            Ambiguous = $readings.Count -gt 1; RepeatedRule = @($chains | Where-Object { $names = $_ -split '\+'; @($names | Sort-Object -Unique).Count -lt $names.Count }).Count -gt 0 })
    }
    $strata = @($rows | Group-Object Chain | Sort-Object Count -Descending | ForEach-Object {
        $group = $_.Group
        [pscustomobject]@{ Chain = $_.Name; Words = $group.Count
            ExactPercent = Get-JudgeShare @($group | Where-Object Exact).Count $group.Count
            SegmentsPercent = Get-JudgeShare @($group | Where-Object Segments).Count $group.Count
            AmbiguousPercent = Get-JudgeShare @($group | Where-Object Ambiguous).Count $group.Count
            Mismatches = @($group | Where-Object { -not $_.Exact } | Select-Object -First $script:JudgeLimits.Examples | ForEach-Object { "$($_.Word): $($_.Readings) / $($_.Reference)" }) }
    })
    $totals = [pscustomobject]@{ Words = $rows.Count; ExactWords = @($rows | Where-Object Exact).Count
        ExactPercent = Get-JudgeShare @($rows | Where-Object Exact).Count $rows.Count
        SegmentsPercent = Get-JudgeShare @($rows | Where-Object Segments).Count $rows.Count
        AmbiguousPercent = Get-JudgeShare @($rows | Where-Object Ambiguous).Count $rows.Count
        RepeatedRuleWords = @($rows | Where-Object RepeatedRule).Count
        HeldOutWords = @($rows | Where-Object { $_.Id % 2 -eq 1 }).Count
        HeldOutExactPercent = Get-JudgeShare @($rows | Where-Object { $_.Id % 2 -eq 1 -and $_.Exact }).Count @($rows | Where-Object { $_.Id % 2 -eq 1 }).Count }
    New-JudgeScore 'Composition' $strata $totals 'Agreement with the lexicon pronunciation of the whole form, which composition did not consult; the lexicon is the reference notation, not independent evidence.'
}

function Get-JudgeStems([string] $Word, [string] $Affix, [string] $Position) {
    if ($Position -ceq 'Prefix') { return $Word.Substring($Affix.Length) }
    $base = $Word.Substring(0, $Word.Length - $Affix.Length)
    $base; $base + 'e'
    if ($Affix.StartsWith('i')) { $base + 'y' }
    if ($base.Length -ge 2 -and $base[-1] -eq $base[-2]) { $base.Substring(0, $base.Length - 1) }
}

function Measure-JudgeCompositionRecall {
    Import-JudgePhonemizer
    $lexicon = $script:JudgeContext.Lexicon; $rows = [Collections.Generic.List[object]]::new()
    for ($id = 0; $id -lt $lexicon::Count(); $id++) {
        $word = $lexicon::Form($id)
        if ($word.Length -lt $script:JudgeLimits.MinimumRecallWord -or $word -cnotmatch '^[a-z]+$') { continue }
        $hit = $null
        foreach ($position in $script:JudgeAffixes.Keys) {
            foreach ($affix in $script:JudgeAffixes[$position]) {
                $attached = if ($position -ceq 'Suffix') { $word.EndsWith($affix, [StringComparison]::Ordinal) } else { $word.StartsWith($affix, [StringComparison]::Ordinal) }
                if (-not $attached -or $word.Length - $affix.Length -lt $script:JudgeLimits.MinimumStem) { continue }
                $stem = Get-JudgeStems $word $affix $position | Where-Object { $_.Length -ge $script:JudgeLimits.MinimumStem -and $lexicon::Find($_) -ge 0 } | Select-Object -First 1
                if ($stem) {
                    $restored = $position -ceq 'Suffix' -and $stem -cne $word.Substring(0, $word.Length - $affix.Length)
                    $hit = [pscustomobject]@{ Affix = "$position $affix"; Stem = $stem; Restored = $restored }; break
                }
            }
            if ($null -ne $hit) { break }
        }
        if ($null -eq $hit) { continue }
        # A parse that applies one rule twice (brass as bra + s + s) is an error the Composition judge counts, not a parse.
        $parsed = @($script:JudgeContext.Compose.Invoke($word) | Where-Object { $_.Root -cne $word } | Where-Object { $names = (Get-JudgeRuleChain $_) -split '\+'; @($names | Sort-Object -Unique).Count -eq $names.Count }).Count -gt 0
        $rows.Add([pscustomobject]@{ Word = $word; Affix = $hit.Affix; Stem = $hit.Stem; Restored = $hit.Restored; Parsed = $parsed })
    }
    $strata = @($rows | Group-Object Affix | Sort-Object Count -Descending | ForEach-Object {
        $group = $_.Group; $restored = @($group | Where-Object Restored)
        [pscustomobject]@{ Affix = $_.Name; Words = $group.Count; ParsedPercent = Get-JudgeShare @($group | Where-Object Parsed).Count $group.Count
            RestoredWords = $restored.Count; RestoredParsedPercent = Get-JudgeShare @($restored | Where-Object Parsed).Count $restored.Count
            Unparsed = @($group | Where-Object { -not $_.Parsed } | Select-Object -First $script:JudgeLimits.Examples | ForEach-Object Word) }
    })
    $restoredAll = @($rows | Where-Object Restored)
    $totals = [pscustomobject]@{ Words = $rows.Count; ParsedWords = @($rows | Where-Object Parsed).Count; ParsedPercent = Get-JudgeShare @($rows | Where-Object Parsed).Count $rows.Count
        RestoredWords = $restoredAll.Count; RestoredParsedPercent = Get-JudgeShare @($restoredAll | Where-Object Parsed).Count $restoredAll.Count }
    New-JudgeScore 'CompositionRecall' $strata $totals 'Whether a parse exists, not whether it is correct; an affix-shaped spelling on a lexicon stem is not always a derivation.'
}

function Get-JudgeParagraphs {
    # Blank-line paragraphs at a fixed stride through each corpus text, in name order, joined onto one line.
    $files = @(Get-ChildItem -LiteralPath $script:JudgeContext.Text -Filter '*.txt' -File | Sort-Object Name)
    if (-not $files.Count) { throw "No corpus text under $($script:JudgeContext.Text)." }
    foreach ($file in $files) {
        $paragraphs = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").Split([string[]]@("`n`n"), [StringSplitOptions]::None)
        for ($index = 0; $index -lt $paragraphs.Length; $index += $ParagraphStride) {
            $paragraph = $paragraphs[$index].Replace("`n", ' ').Trim()
            if ($paragraph.Length -lt $script:JudgeLimits.ParagraphMinimum -or $paragraph.Length -gt $script:JudgeLimits.ParagraphMaximum) { continue }
            [pscustomobject]@{ Source = $file.Name; Paragraph = $index; Text = $paragraph }
        }
    }
}

function Measure-JudgeCorpusCoverage {
    # Best effort: every word token should be spoken. Scored per token (a pronunciation, its source) and per paragraph
    # (complete), with grammatical roles as the reachability of clause composition.
    Import-JudgePhonemizer
    $rows = [Collections.Generic.List[object]]::new(); $sources = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $silent = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal); $silentWords = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($item in Get-JudgeParagraphs) {
        $index = $item.Paragraph; $paragraph = $item.Text
            # A paragraph the phonemizer throws on is scored as incomplete and unspoken with status Exception, never skipped.
            try { $result = $script:JudgeContext.Run.Invoke($paragraph) }
            catch {
                $failure = $_.Exception; while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
                $rows.Add([pscustomobject]@{ Source = $item.Source; Paragraph = $index; Complete = $false
                    GrammarStatus = "Exception:$($failure.GetType().Name)"; Words = 0; SpokenWords = 0; RoleWords = 0 })
                continue
            }
            $words = @($result.Tokens | Where-Object { $_.Word -and [char]::IsLetter($_.Word[0]) }); $spoken = 0
            foreach ($word in $words) {
                if ($word.Pron) { $spoken++; $source = [string]$word.PronunciationSource; $sources[$source] = 1 + $(if ($sources.ContainsKey($source)) { $sources[$source] } else { 0 }) }
                else { $status = [string]$word.Status; $silent[$status] = 1 + $(if ($silent.ContainsKey($status)) { $silent[$status] } else { 0 }); $silentWords[$word.Word] = 1 + $(if ($silentWords.ContainsKey($word.Word)) { $silentWords[$word.Word] } else { 0 }) }
            }
            $rows.Add([pscustomobject]@{ Source = $item.Source; Paragraph = $index; Complete = [bool]$result.Complete
                GrammarStatus = [string]$result.GrammarStatus; Words = $words.Count; SpokenWords = $spoken
                RoleWords = @($words | Where-Object { @($_.Roles).Count }).Count })
    }
    $sum = { param($Rows, $Name) [int]($Rows | Measure-Object $Name -Sum).Sum }
    $strata = @($rows | Group-Object Source | ForEach-Object {
        $group = $_.Group; $words = & $sum $group 'Words'
        [pscustomobject]@{ Source = $_.Name; Paragraphs = $group.Count; CompletePercent = Get-JudgeShare @($group | Where-Object Complete).Count $group.Count
            Words = $words; SpokenPercent = Get-JudgeShare (& $sum $group 'SpokenWords') $words; RolePercent = Get-JudgeShare (& $sum $group 'RoleWords') $words
            GrammarStatus = @($group | Group-Object GrammarStatus | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) }
    })
    $wordCount = & $sum $rows 'Words'; $spokenCount = & $sum $rows 'SpokenWords'; $roleCount = & $sum $rows 'RoleWords'
    $completeCount = @($rows | Where-Object Complete).Count
    $totals = [pscustomobject]@{ Paragraphs = $rows.Count; Stride = $ParagraphStride
        CompleteParagraphs = $completeCount; CompletePercent = Get-JudgeShare $completeCount $rows.Count
        ExceptionParagraphs = @($rows | Where-Object { $_.GrammarStatus.StartsWith('Exception:') }).Count
        Words = $wordCount; SpokenWords = $spokenCount; SpokenPercent = Get-JudgeShare $spokenCount $wordCount
        RoleWords = $roleCount; RolePercent = Get-JudgeShare $roleCount $wordCount
        PronunciationSources = @($sources.Keys | Sort-Object | ForEach-Object { "$_=$($sources[$_])" })
        SilentStatus = @($silent.Keys | Sort-Object | ForEach-Object { "$_=$($silent[$_])" })
        SilentWords = @($silentWords.GetEnumerator() | Sort-Object { -$_.Value }, Key | ForEach-Object { "$($_.Key)=$($_.Value)" })
        GrammarStatus = @($rows | Group-Object GrammarStatus | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) }
    New-JudgeScore 'CorpusCoverage' $strata $totals 'Whether each word token is spoken and from which source; pronunciation and role correctness are not measured here.'
}

function Measure-JudgePhonics {
    # Sounding out with the word's own lexicon entry withheld, scored against that entry. The reader is the driver's
    # CoreDriver.SoundOut(string word, int withheldLexicalId) returning its readings (string[], best first); until the
    # driver has it, every probe is scored as not read.
    Import-JudgePhonemizer
    $lexicon = $script:JudgeContext.Lexicon
    $method = $script:JudgeContext.Run.Method.DeclaringType.GetMethod('SoundOut', [Type[]]@([string], [int]))
    $reader = if ($null -ne $method) { $method.CreateDelegate([Func[string,int,string[]]]) } else { $null }
    $rows = [Collections.Generic.List[object]]::new()
    for ($id = 0; $id -lt $lexicon::Count(); $id += $script:JudgeLimits.PhonicsStride) {
        $word = $lexicon::Form($id)
        if ($word.Length -lt $script:JudgeLimits.MinimumWord -or $word -cnotmatch '^[a-z]+$') { continue }
        $reference = Get-JudgeLexiconReadings $id
        if (-not $reference.Count) { continue }
        [string[]] $readings = @(if ($null -ne $reader) { $reader.Invoke($word, $id) | Where-Object { $_ } })
        $segments = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($phones in $reference) { [void]$segments.Add((Get-JudgeSegments $phones)) }
        $first = if ($readings.Count) { $readings[0] } else { '' }
        $rows.Add([pscustomobject]@{ Word = $word; Length = $word.Length; Read = $readings.Count -gt 0
            FirstExact = $reference.Contains($first); AnyExact = @($readings | Where-Object { $reference.Contains($_) }).Count -gt 0
            FirstSegments = $first -and $segments.Contains((Get-JudgeSegments $first)); Readings = $readings.Count })
    }
    $score = { param($Rows) [ordered]@{ Words = $Rows.Count; ReadPercent = Get-JudgeShare @($Rows | Where-Object Read).Count $Rows.Count
        FirstExactPercent = Get-JudgeShare @($Rows | Where-Object FirstExact).Count $Rows.Count
        AnyExactPercent = Get-JudgeShare @($Rows | Where-Object AnyExact).Count $Rows.Count
        FirstSegmentsPercent = Get-JudgeShare @($Rows | Where-Object FirstSegments).Count $Rows.Count } }
    $strata = @($rows | Group-Object { if ($_.Length -le 4) { 'letters 3-4' } elseif ($_.Length -le 7) { 'letters 5-7' } else { 'letters 8+' } } | Sort-Object Name | ForEach-Object {
        $values = & $score $_.Group; $values.Insert(0, 'Stratum', $_.Name); [pscustomobject]$values })
    $totals = & $score $rows; $totals.Reader = if ($null -ne $reader) { 'CoreDriver.SoundOut' } else { 'Absent' }
    New-JudgeScore 'Phonics' $strata ([pscustomobject]$totals) 'Lexicon forms at a fixed stride with their own entry withheld from the reader; the lexicon is the reference notation.'
}

# Break levels between words, after the three pause units of classical rhetoric: komma (a short unit), kolon (a
# longer unit) and periodos (a complete thought). The author's marks are the reference: comma is komma; semicolon,
# colon, dash, parenthesis and an inner ellipsis are kolon; a sentence stop or a paragraph end is periodos.
$script:JudgeBreakMarks = [ordered]@{ ',' = 1; ';' = 2; ':' = 2; '—' = 2; '–' = 2; '(' = 2; ')' = 2; '[' = 2; ']' = 2; '…' = 2; '.' = 3; '?' = 3; '!' = 3 }
$script:JudgeBreakNames = @('None', 'Komma', 'Kolon', 'Periodos')
# A period after these words abbreviates them and is not a break.
$script:JudgeAbbreviations = @('mr', 'mrs', 'ms', 'dr', 'st', 'prof', 'rev', 'gen', 'col', 'capt', 'lt', 'sr', 'jr', 'vol', 'no', 'vs', 'viz', 'etc', 'ib', 'ibid', 'cf', 'pp', 'ch', 'sect', 'fig', 'ed', 'i', 'e', 'g')

function Split-JudgeBreaks([string] $Text) {
    # Words (letters, digits and word-internal apostrophes, hyphens and digit-group separators) and the strongest
    # author break after each word. Typed character traversal; no regular expressions.
    $words = [Collections.Generic.List[string]]::new(); $levels = [Collections.Generic.List[int]]::new(); $at = 0
    while ($at -lt $Text.Length) {
        $c = $Text[$at]
        if ([char]::IsLetterOrDigit($c)) {
            $start = $at
            while ($at -lt $Text.Length) {
                $d = $Text[$at]
                $inner = $at + 1 -lt $Text.Length -and $at -gt $start
                if ([char]::IsLetterOrDigit($d)) { $at++; continue }
                if ($inner -and ($d -eq "'" -or $d -eq [char]8217 -or $d -eq '-') -and [char]::IsLetter($Text[$at - 1]) -and [char]::IsLetter($Text[$at + 1])) { $at++; continue }
                if ($inner -and ($d -eq ',' -or $d -eq '.') -and [char]::IsDigit($Text[$at - 1]) -and [char]::IsDigit($Text[$at + 1])) { $at++; continue }
                break
            }
            $words.Add($Text.Substring($start, $at - $start)); $levels.Add(0); continue
        }
        $level = 0
        if ($c -eq '-' -and $at + 1 -lt $Text.Length -and $Text[$at + 1] -eq '-') { $level = 2; $at++ }
        elseif ($c -eq '.' -and $at + 2 -lt $Text.Length -and $Text[$at + 1] -eq '.' -and $Text[$at + 2] -eq '.') { $level = 2; $at += 2 }
        elseif ($c -eq '.' -and $words.Count -and $script:JudgeAbbreviations -contains $words[$words.Count - 1].ToLowerInvariant()) { $level = 0 }
        elseif ($script:JudgeBreakMarks.Contains([string]$c)) { $level = $script:JudgeBreakMarks[[string]$c] }
        if ($level -and $words.Count) { $levels[$levels.Count - 1] = [Math]::Max($levels[$levels.Count - 1], $level) }
        $at++
    }
    if ($words.Count) { $levels[$levels.Count - 1] = 3 }
    [pscustomobject]@{ Words = $words.ToArray(); Levels = $levels.ToArray() }
}

function Measure-JudgePhrasing {
    # The author's punctuation is removed and the reader restores breaks between the bare words. The reader is the
    # driver's CoreDriver.Phrase(string[] words) returning one level (0 to 3) after each word; until the driver has
    # it, the only break placed is the paragraph end, which is known from the input.
    Import-JudgePhonemizer
    $method = $script:JudgeContext.Run.Method.DeclaringType.GetMethod('Phrase', [Type[]]@([string[]]))
    $reader = if ($null -ne $method) { $method.CreateDelegate([Func[string[],int[]]]) } else { $null }
    $reference = [int[]]::new(4); $predicted = [int[]]::new(4); $found = [int[]]::new(4); $levelExact = [int[]]::new(4)
    $gaps = 0; $paragraphs = 0; $truePositive = 0; $predictedBreaks = 0
    foreach ($item in Get-JudgeParagraphs) {
        $split = Split-JudgeBreaks $item.Text
        if ($split.Words.Length -lt 2) { continue }
        $paragraphs++
        [int[]] $guess = if ($null -ne $reader) { $reader.Invoke([string[]]$split.Words) } else { $null }
        if ($null -eq $guess) { $guess = [int[]]::new($split.Words.Length); $guess[$guess.Length - 1] = 3 }
        if ($guess.Length -ne $split.Words.Length) { throw 'The phrasing reader returned a level count different from its word count.' }
        for ($i = 0; $i -lt $split.Words.Length; $i++) {
            $want = $split.Levels[$i]; $got = [Math]::Max(0, [Math]::Min(3, $guess[$i])); $gaps++
            $reference[$want]++; $predicted[$got]++
            if ($got -gt 0) { $predictedBreaks++ }
            if ($want -gt 0 -and $got -gt 0) { $truePositive++; $found[$want]++ }
            if ($want -gt 0 -and $got -eq $want) { $levelExact[$want]++ }
        }
    }
    $referenceBreaks = $reference[1] + $reference[2] + $reference[3]
    $precision = Get-JudgeShare $truePositive $predictedBreaks; $recall = Get-JudgeShare $truePositive $referenceBreaks
    $strata = @(foreach ($level in 1..3) {
        [pscustomobject]@{ Level = $script:JudgeBreakNames[$level]; Reference = $reference[$level]; Predicted = $predicted[$level]
            RecallPercent = Get-JudgeShare $found[$level] $reference[$level]; LevelExactPercent = Get-JudgeShare $levelExact[$level] $reference[$level] }
    })
    $totals = [pscustomobject]@{ Paragraphs = $paragraphs; Gaps = $gaps; ReferenceBreaks = $referenceBreaks; PredictedBreaks = $predictedBreaks
        BreakPrecisionPercent = $precision; BreakRecallPercent = $recall
        BreakF1Percent = if ($precision + $recall) { [Math]::Round(2 * $precision * $recall / ($precision + $recall), 1) } else { 0.0 }
        LevelExactPercent = Get-JudgeShare ($levelExact[1] + $levelExact[2] + $levelExact[3]) $referenceBreaks
        Reader = if ($null -ne $reader) { 'CoreDriver.Phrase' } else { 'Absent' } }
    New-JudgeScore 'Phrasing' $strata $totals 'Author punctuation as the reference for where a reader breaks and how strongly; breaks a speaker makes where the author wrote none count against precision here and are checked against audio separately.'
}

# The ratchet: each measure may improve but never regress. Raised by the judges' owner when a change improves it.
$script:JudgeBaseline = @(
    [pscustomobject]@{ Judge = 'Composition'; Measure = 'ExactWords'; Better = 'Higher'; Value = 5497 }
    [pscustomobject]@{ Judge = 'Composition'; Measure = 'ExactPercent'; Better = 'Higher'; Value = 76.8 }
    [pscustomobject]@{ Judge = 'Composition'; Measure = 'RepeatedRuleWords'; Better = 'Lower'; Value = 1 }
    [pscustomobject]@{ Judge = 'Composition'; Measure = 'HeldOutExactPercent'; Better = 'Higher'; Value = 77.7 }
    [pscustomobject]@{ Judge = 'CompositionRecall'; Measure = 'ParsedWords'; Better = 'Higher'; Value = 7025 }
    [pscustomobject]@{ Judge = 'CompositionRecall'; Measure = 'ParsedPercent'; Better = 'Higher'; Value = 34.0 }
    [pscustomobject]@{ Judge = 'CorpusCoverage'; Measure = 'SpokenPercent'; Better = 'Higher'; Value = 100.0 }
    [pscustomobject]@{ Judge = 'CorpusCoverage'; Measure = 'CompletePercent'; Better = 'Higher'; Value = 23.4 }
    [pscustomobject]@{ Judge = 'CorpusCoverage'; Measure = 'ExceptionParagraphs'; Better = 'Lower'; Value = 1 }
    [pscustomobject]@{ Judge = 'CorpusCoverage'; Measure = 'RoleWords'; Better = 'Higher'; Value = 12 }
    [pscustomobject]@{ Judge = 'Phonics'; Measure = 'FirstExactPercent'; Better = 'Higher'; Value = 15.9 }
    [pscustomobject]@{ Judge = 'Phonics'; Measure = 'FirstSegmentsPercent'; Better = 'Higher'; Value = 32.7 }
    [pscustomobject]@{ Judge = 'Phrasing'; Measure = 'BreakF1Percent'; Better = 'Higher'; Value = 13.3 }
    [pscustomobject]@{ Judge = 'Phrasing'; Measure = 'LevelExactPercent'; Better = 'Higher'; Value = 7.1 }
)

function Test-JudgeRatchet([object[]] $Scores) {
    $byJudge = @{}; foreach ($score in $Scores) { $byJudge[$score.Judge] = $score }
    $rows = @(foreach ($record in $script:JudgeBaseline) {
        $current = [double]$byJudge[$record.Judge].Totals.($record.Measure)
        $delta = if ($record.Better -ceq 'Higher') { $current - $record.Value } else { $record.Value - $current }
        [pscustomobject]@{ PSTypeName = 'Kokoro.StudentJudgeRatchet'; Judge = $record.Judge; Measure = $record.Measure
            Baseline = $record.Value; Current = $current
            Verdict = if ([Math]::Round($delta, 1) -lt 0) { 'Regressed' } elseif ([Math]::Round($delta, 1) -gt 0) { 'Improved' } else { 'Held' } }
    })
    $line = ($rows | ForEach-Object { '{0}.{1} {2}' -f $_.Judge, $_.Measure, $_.Current }) -join ', '
    $regressed = @($rows | Where-Object Verdict -CEQ 'Regressed')
    if ($regressed.Count) { throw ('Student judge ratchet regressed: ' + (($regressed | ForEach-Object { "$($_.Judge).$($_.Measure) $($_.Current) (baseline $($_.Baseline))" }) -join '; ')) }
    [pscustomobject]@{ PSTypeName = 'Kokoro.StudentJudgeRatchetResult'; Passed = $true; Measures = $rows; Score = $line
        Improved = @($rows | Where-Object Verdict -CEQ 'Improved').Count }
}

$script:JudgeSteps = [ordered]@{
    Composition = { Measure-JudgeComposition }
    CompositionRecall = { Measure-JudgeCompositionRecall }
    CorpusCoverage = { Measure-JudgeCorpusCoverage }
    Phonics = { Measure-JudgePhonics }
    Phrasing = { Measure-JudgePhrasing }
}
if ($Step -ceq 'All') { foreach ($name in $script:JudgeSteps.Keys) { & $script:JudgeSteps[$name] } }
elseif ($Step -ceq 'Ratchet') { Test-JudgeRatchet @(foreach ($name in $script:JudgeSteps.Keys) { & $script:JudgeSteps[$name] }) }
else { & $script:JudgeSteps[$Step] }
