param([string]$Out, [int]$Max = 4000)
# Prose sentences from Markdown under C:\Dev\.vendor and our docs: 5-18 words, letters and ordinary punctuation only.
$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$rows = [System.Collections.Generic.List[string]]::new()
$files = Get-ChildItem C:\Dev\.vendor, C:\Dev\Kokoro-Hexagon\docs, C:\Dev\Pwsh-Development\docs -Recurse -Filter *.md -File -ErrorAction SilentlyContinue | Sort-Object FullName
foreach ($f in $files) {
    $inCode = $false
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
        if ($inCode -or $line -match '^\s*([#|>*-]|\d+\.|\[|!|<)') { continue }
        foreach ($s in [regex]::Split($line, '(?<=[.!?])\s+')) {
            $s = $s.Trim()
            if ($s -notmatch "^[A-Z][A-Za-z ,'\-]+[.!?]$") { continue }
            $w = ($s -split '\s+').Count
            if ($w -lt 5 -or $w -gt 18) { continue }
            if ($seen.Add($s)) { $rows.Add($s); if ($rows.Count -ge $Max) { break } }
        }
        if ($rows.Count -ge $Max) { break }
    }
    if ($rows.Count -ge $Max) { break }
}
$rows | ConvertTo-Json | Set-Content $Out -Encoding utf8
"$($rows.Count) sentences from $($files.Count) files"
