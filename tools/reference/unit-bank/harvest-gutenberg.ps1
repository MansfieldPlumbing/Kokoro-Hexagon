param([string]$Out, [int]$Max = 60000)
# Prose sentences from the local Gutenberg books: body between the START/END markers, paragraphs joined, 5-18 words.
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rows = [System.Collections.Generic.List[string]]::new()
$files = Get-ChildItem C:\TEMP\sma-english-projection\inputs\gutenberg -Recurse -Filter *.txt -File | Sort-Object FullName
$perBook = [math]::Ceiling($Max / $files.Count)
foreach ($f in $files) {
    $text = [IO.File]::ReadAllText($f.FullName)
    $a = $text.IndexOf('*** START'); $b = $text.IndexOf('*** END')
    if ($a -ge 0) { $text = $text.Substring($text.IndexOf("`n", $a) + 1) }
    if ($b -gt $a -and $a -ge 0) { $text = $text.Substring(0, [math]::Max(0, $text.IndexOf('*** END'))) }
    $n = 0
    foreach ($para in [regex]::Split($text, '\r?\n\s*\r?\n')) {
        $p = [regex]::Replace($para, '\s+', ' ').Replace('_', '').Replace([char]0x2019, "'").Replace([char]0x201C, '"').Replace([char]0x201D, '"')
        foreach ($s in [regex]::Split($p, '(?<=[.!?])\s+')) {
            $s = $s.Trim()
            if ($s -notmatch "^[A-Z][A-Za-z ,;'\-]+[.!?]$") { continue }
            $w = ($s -split '\s+').Count
            if ($w -lt 5 -or $w -gt 18) { continue }
            if ($seen.Add($s)) { $rows.Add($s); $n++ }
            if ($n -ge $perBook) { break }
        }
        if ($n -ge $perBook) { break }
    }
}
$rows | ConvertTo-Json | Set-Content $Out -Encoding utf8
"$($rows.Count) sentences from $($files.Count) books"
