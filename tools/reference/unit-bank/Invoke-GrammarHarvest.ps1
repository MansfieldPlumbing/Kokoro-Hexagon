param([string]$Raw = 'C:\Dev\Kokoro-Hexagon\build\grammar-corpus\raw', [string]$Out = 'C:\Dev\Kokoro-Hexagon\build\grammar-corpus')
# Grammar books -> labeled example sentences -> phonemizer driver -> capture queue and coverage report.
# Book text is data: nothing from it is executed. Labels come from the section heading each example sits under.
$books = @{ 14006 = 'Baskervill-Sewell'; 11615 = 'Brown'; 30036 = 'Hamilton' }
$dll = Get-ChildItem C:\Dev\Kokoro-Hexagon\build\phonemizer\english\driver -Recurse -Filter 'Dev.MansfieldPlumbing.English.Driver.*.dll' | Sort-Object LastWriteTime | Select-Object -Last 1
$asm = [Reflection.Assembly]::LoadFrom($dll.FullName)
$run = [Func[string, object]]$asm.GetType('CoreDriver', $true).GetMethod('Run').CreateDelegate([Func[string, object]])
# Full Moby part-of-speech tags (includes P preposition, C conjunction, v adverb, D/I articles that the capability table omits)
$moby = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in [IO.File]::ReadLines('C:\Dev\Kokoro-Hexagon\build\phonemizer\inputs\public-domain-moby\capabilities.txt', [Text.Encoding]::Latin1)) {
    $k = $line.IndexOf([char]215); if ($k -lt 1) { continue }
    $w = $line.Substring(0, $k); if (-not $moby.ContainsKey($w)) { $moby[$w] = $line.Substring($k + 1) }
}
$heading = [regex]'^(?:(?:CHAPTER|LESSON|PART|SECTION)\s+)?(?:[IVXLC\d]+\.\s+)?([A-Z][A-Z ,\-]{3,60})\.?\s*$'
$example = [regex]"^\s{2,}[`"']?([A-Z][A-Za-z ,;'\-]+[.!?])[`"']?(?:\s*[-\u2014]{1,2}\s*[A-Z][A-Za-z. ]{1,40})?\s*$"
$quoted = [regex]"[`"\u201C]([A-Z][A-Za-z ,;'\-]{8,}[.!?])[`"\u201D]"
$rows = [Collections.Generic.List[object]]::new(); $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($id in $books.Keys) {
    $path = Join-Path $Raw "pg$id.txt"; if (-not (Test-Path $path)) { continue }
    $text = [IO.File]::ReadAllText($path); $a = $text.IndexOf('*** START'); $b = $text.IndexOf('*** END')
    if ($a -ge 0 -and $b -gt $a) { $text = $text.Substring($a, $b - $a) }
    $section = ''; $n = 0
    foreach ($line in $text -split '\r?\n') {
        $n++
        $h = $heading.Match($line); if ($h.Success -and $line.Trim().Length -lt 70) { $section = $h.Groups[1].Value.Trim(); continue }
        $cands = [Collections.Generic.List[string]]::new()
        $m = $example.Match($line); if ($m.Success) { $cands.Add($m.Groups[1].Value) }
        foreach ($q in $quoted.Matches($line)) { $cands.Add($q.Groups[1].Value) }
        foreach ($s in $cands) {
            $s = $s.Trim(); $w = ($s -split '\s+').Count
            if ($w -lt 3 -or $w -gt 20 -or -not $seen.Add($s)) { continue }
            # Sections that teach by error (false syntax, improprieties, errors) hold deliberately incorrect examples.
            $negative = $section -match 'FALSE|IMPROPRIET|ERROR|CORRECTION'
            $rows.Add([pscustomobject]@{ text = $s; book = $books[$id]; ebook = $id; line = $n; section = $section; deliberateError = $negative })
        }
    }
}
# Phonemize and annotate
$ok = 0; $grammar = @{}
foreach ($r in $rows) {
    $res = $run.Invoke($r.text); $ph = ([string]$res.KokoroPhones -replace ' ([.,?!;])', '$1').Trim()
    $words = @([regex]::Matches($r.text, "[A-Za-z']+") | ForEach-Object Value)
    $r | Add-Member phonemes $ph
    $r | Add-Member grammarStatus ([string]$res.GrammarStatus)
    $r | Add-Member pronunciationStatus ([string]$res.PronunciationStatus)
    $r | Add-Member oov @($res.OovSpans | ForEach-Object Word)
    $r | Add-Member wordClasses @($words | ForEach-Object { $t = $null; if ($moby.TryGetValue($_, [ref]$t)) { $t } else { '' } })
    if ($ph) { $ok++ }; $grammar[$r.grammarStatus] = 1 + [int]$grammar[$r.grammarStatus]
}
New-Item -ItemType Directory -Force $Out | Out-Null
$rows | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out 'examples.json') -Encoding utf8
@($rows | Where-Object phonemes | ForEach-Object { [ordered]@{ text = $_.text; phonemes = $_.phonemes; source = "gutenberg-$($_.ebook):$($_.line)" } }) | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Out 'capture-queue.json') -Encoding utf8
'{0} examples ({1}); phonemized {2}; grammar status: {3}' -f $rows.Count, (($rows | Group-Object book | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '), $ok, (($grammar.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
'sections with most examples: ' + (($rows | Group-Object section | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join '; ')
$rows | Where-Object phonemes | Get-Random -Count 4 -SetSeed 2 | ForEach-Object { '  [{0}] {1}' -f $_.section, $_.text }
