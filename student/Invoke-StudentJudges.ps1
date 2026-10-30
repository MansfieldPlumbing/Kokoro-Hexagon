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
      RoleCoverage      Corpus paragraphs at a fixed stride through the phonemizer: completeness, grammar status
                        and the share of word tokens that carry a grammatical role clause composition can consume.
      All               Every judge above.
#>
param(
    [ValidateSet('Composition', 'CompositionRecall', 'RoleCoverage', 'All')][string] $Step = 'All',
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
    ParagraphMinimum = 40; ParagraphMaximum = 2000; Examples = 3 }

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
        $rows.Add([pscustomobject]@{ Word = $word; Chain = $chains[0]; Readings = $readings -join '|'; Reference = @($reference) -join '|'
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
    $totals = [pscustomobject]@{ Words = $rows.Count
        ExactPercent = Get-JudgeShare @($rows | Where-Object Exact).Count $rows.Count
        SegmentsPercent = Get-JudgeShare @($rows | Where-Object Segments).Count $rows.Count
        AmbiguousPercent = Get-JudgeShare @($rows | Where-Object Ambiguous).Count $rows.Count
        RepeatedRuleWords = @($rows | Where-Object RepeatedRule).Count }
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
        $parsed = @($script:JudgeContext.Compose.Invoke($word) | Where-Object { $_.Root -cne $word }).Count -gt 0
        $rows.Add([pscustomobject]@{ Word = $word; Affix = $hit.Affix; Stem = $hit.Stem; Restored = $hit.Restored; Parsed = $parsed })
    }
    $strata = @($rows | Group-Object Affix | Sort-Object Count -Descending | ForEach-Object {
        $group = $_.Group; $restored = @($group | Where-Object Restored)
        [pscustomobject]@{ Affix = $_.Name; Words = $group.Count; ParsedPercent = Get-JudgeShare @($group | Where-Object Parsed).Count $group.Count
            RestoredWords = $restored.Count; RestoredParsedPercent = Get-JudgeShare @($restored | Where-Object Parsed).Count $restored.Count
            Unparsed = @($group | Where-Object { -not $_.Parsed } | Select-Object -First $script:JudgeLimits.Examples | ForEach-Object Word) }
    })
    $restoredAll = @($rows | Where-Object Restored)
    $totals = [pscustomobject]@{ Words = $rows.Count; ParsedPercent = Get-JudgeShare @($rows | Where-Object Parsed).Count $rows.Count
        RestoredWords = $restoredAll.Count; RestoredParsedPercent = Get-JudgeShare @($restoredAll | Where-Object Parsed).Count $restoredAll.Count }
    New-JudgeScore 'CompositionRecall' $strata $totals 'Whether a parse exists, not whether it is correct; an affix-shaped spelling on a lexicon stem is not always a derivation.'
}

function Measure-JudgeRoleCoverage {
    Import-JudgePhonemizer
    $files = @(Get-ChildItem -LiteralPath $script:JudgeContext.Text -Filter '*.txt' -File | Sort-Object Name)
    if (-not $files.Count) { throw "No corpus text under $($script:JudgeContext.Text)." }
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $paragraphs = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").Split([string[]]@("`n`n"), [StringSplitOptions]::None)
        for ($index = 0; $index -lt $paragraphs.Length; $index += $ParagraphStride) {
            $paragraph = $paragraphs[$index].Replace("`n", ' ').Trim()
            if ($paragraph.Length -lt $script:JudgeLimits.ParagraphMinimum -or $paragraph.Length -gt $script:JudgeLimits.ParagraphMaximum) { continue }
            # A paragraph the phonemizer throws on is scored as incomplete with status Exception, never skipped.
            try { $result = $script:JudgeContext.Run.Invoke($paragraph) }
            catch {
                $failure = $_.Exception; while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
                $rows.Add([pscustomobject]@{ Source = $file.Name; Paragraph = $index; Complete = $false
                    GrammarStatus = "Exception:$($failure.GetType().Name)"; Words = 0; RoleWords = 0 })
                continue
            }
            $words = @($result.Tokens | Where-Object { $_.Word -and [char]::IsLetter($_.Word[0]) })
            $rows.Add([pscustomobject]@{ Source = $file.Name; Paragraph = $index; Complete = [bool]$result.Complete
                GrammarStatus = [string]$result.GrammarStatus; Words = $words.Count; RoleWords = @($words | Where-Object { @($_.Roles).Count }).Count })
        }
    }
    $wordCount = [int]($rows | Measure-Object Words -Sum).Sum; $roleCount = [int]($rows | Measure-Object RoleWords -Sum).Sum
    $strata = @($rows | Group-Object Source | ForEach-Object {
        $group = $_.Group; $words = [int]($group | Measure-Object Words -Sum).Sum
        [pscustomobject]@{ Source = $_.Name; Paragraphs = $group.Count; CompletePercent = Get-JudgeShare @($group | Where-Object Complete).Count $group.Count
            Words = $words; RolePercent = Get-JudgeShare ([int]($group | Measure-Object RoleWords -Sum).Sum) $words
            GrammarStatus = @($group | Group-Object GrammarStatus | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) }
    })
    $totals = [pscustomobject]@{ Paragraphs = $rows.Count; Stride = $ParagraphStride; CompletePercent = Get-JudgeShare @($rows | Where-Object Complete).Count $rows.Count
        Words = $wordCount; RoleWords = $roleCount; RolePercent = Get-JudgeShare $roleCount $wordCount
        GrammarStatus = @($rows | Group-Object GrammarStatus | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) }
    New-JudgeScore 'RoleCoverage' $strata $totals 'Reachability of clause composition from text through phonemizer roles; role correctness is not measured.'
}

$script:JudgeSteps = [ordered]@{
    Composition = { Measure-JudgeComposition }
    CompositionRecall = { Measure-JudgeCompositionRecall }
    RoleCoverage = { Measure-JudgeRoleCoverage }
}
if ($Step -ceq 'All') { foreach ($name in $script:JudgeSteps.Keys) { & $script:JudgeSteps[$name] } }
else { & $script:JudgeSteps[$Step] }
