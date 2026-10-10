param([int]$TrainSentences = 20000, [int]$TestFrom = 40000, [string]$HeldOut = (Join-Path $PSScriptRoot 'heldout.json'))
# Linguistic stream (driver Tokens aligned to Kokoro phoneme positions + Moby word classes) x acoustic stream (per-token
# stock N mean, voiced log F0 mean, duration). Backoff-table prediction per feature set; held-out RMSE vs phone-only.
Add-Type -AssemblyName System.IO.Compression
$bank = 'C:\Dev\Kokoro-Hexagon\build\unit-bank'
$order = Get-Content "$bank/order.json" -Raw | ConvertFrom-Json
$dll = Get-ChildItem C:\Dev\Kokoro-Hexagon\build\phonemizer\english\driver -Recurse -Filter 'Dev.MansfieldPlumbing.English.Driver.*.dll' | Sort-Object LastWriteTime | Select-Object -Last 1
$run = [Func[string, object]]([Reflection.Assembly]::LoadFrom($dll.FullName).GetType('CoreDriver', $true).GetMethod('Run').CreateDelegate([Func[string, object]]))
$moby = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($line in [IO.File]::ReadLines('C:\Dev\Kokoro-Hexagon\build\phonemizer\inputs\public-domain-moby\capabilities.txt', [Text.Encoding]::Latin1)) {
    $k = $line.IndexOf([char]215); if ($k -gt 0) { $w = $line.Substring(0, $k); if (-not $moby.ContainsKey($w)) { $moby[$w] = $line.Substring($k + 1) } }
}
$functionWords = [Collections.Generic.HashSet[string]]::new([string[]]('a', 'an', 'the', 'to', 'of', 'and', 'or', 'but', 'in', 'on', 'at', 'for', 'with', 'by', 'from', 'as', 'is', 'are', 'was', 'were', 'be', 'been', 'am', 'can', 'could', 'will', 'would', 'shall', 'should', 'may', 'might', 'must', 'do', 'does', 'did', 'have', 'has', 'had', 'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them', 'my', 'your', 'his', 'its', 'our', 'their', 'that', 'this', 'not', 'so', 'if', 'than', 'then'), [StringComparer]::OrdinalIgnoreCase)
$vowels = [Collections.Generic.HashSet[char]]::new([char[]]'aeiouæɑɒɔəɛɜɪʊʌɐᵻAEIOUWYɚɝ')

# --- acoustic targets ---
function Read-Npy([IO.Compression.ZipArchive]$zip, [string]$name, [type]$t) {
    $ms = [IO.MemoryStream]::new(); $s = $zip.GetEntry("$name.npy").Open(); $s.CopyTo($ms); $s.Dispose(); $b = $ms.ToArray()
    $off = 10 + [BitConverter]::ToUInt16($b, 8); $n = ($b.Length - $off) / 4
    $a = [Array]::CreateInstance($t, $n); [Buffer]::BlockCopy($b, $off, $a, 0, $n * 4); , $a
}
$zip = [IO.Compression.ZipFile]::OpenRead("$bank/token-targets.npz")
$tSent = Read-Npy $zip 'sent' ([int]); $tN = Read-Npy $zip 'nmean' ([float]); $tF = Read-Npy $zip 'lf0' ([float]); $tD = Read-Npy $zip 'dur' ([int]); $zip.Dispose()
$rowOf = [int[]]::new($order.Count + 1); $r = 0
for ($s = 0; $s -lt $order.Count; $s++) { $rowOf[$s] = $r; while ($r -lt $tSent.Length -and $tSent[$r] -eq $s) { $r++ } }; $rowOf[$order.Count] = $r

# --- linguistic stream: per phoneme token feature strings for 9 nested sets ---
function Get-Class([string]$w) {
    if ($functionWords.Contains($w)) { return 'F' }
    $t = $null; if ($moby.TryGetValue($w, [ref]$t) -and $t.Length) { $c = $t[0]; if ('Nph'.Contains($c)) { return 'N' }; if ('Vti'.Contains($c)) { return 'V' }; if ($c -ceq 'A') { return 'A' }; if ($c -ceq 'v') { return 'R' }; return 'F' }
    'U'
}
function Get-Keys([string]$text, [string]$ph) {
    $res = $run.Invoke($text); $wordOf = [int[]]::new($ph.Length); $j = 0; $words = [Collections.Generic.List[string]]::new(); $cls = [Collections.Generic.List[string]]::new()
    for ($q = 0; $q -lt $wordOf.Length; $q++) { $wordOf[$q] = -1 }
    foreach ($tk in $res.Tokens) {
        $p = [string]$tk.Pron; if (-not $p) { continue }
        while ($j -lt $ph.Length -and $ph[$j] -ceq ' ') { $j++ }
        if ($j + $p.Length -gt $ph.Length -or -not $ph.Substring($j, $p.Length).Equals($p, [StringComparison]::Ordinal)) { return $null }
        $wi = $words.Count; $words.Add([string]$tk.Word); $cls.Add($(if ($p.Length -eq 1 -and '.,!?;:'.Contains($p)) { 'P' } else { Get-Class ([string]$tk.Word) }))
        for ($q = 0; $q -lt $p.Length; $q++) { $wordOf[$j + $q] = $wi }; $j += $p.Length
    }
    # groups: new group at a function word after a content word, or after punctuation
    $group = [int[]]::new($words.Count); $g = 0
    for ($w = 0; $w -lt $words.Count; $w++) { if ($w -gt 0 -and (($cls[$w] -ceq 'F' -and $cls[$w - 1] -cne 'F' -and $cls[$w - 1] -cne 'P') -or $cls[$w - 1] -ceq 'P')) { $g++ }; $group[$w] = $g }
    $pad = '###<' + $ph + '>###'; $n = $ph.Length + 2; $keys = [string[, ]]::new($n, 9)
    for ($i = 0; $i -lt $n; $i++) {
        $p = $i + 3; $sym = $pad[$p]; $q = $i - 1; $w = if ($q -ge 0 -and $q -lt $ph.Length) { $wordOf[$q] } else { -1 }
        $st = 0; $x = $p; while ($x -lt $pad.Length -and $pad[$x] -cne ' ' -and -not $vowels.Contains($pad[$x])) { $x++ }
        if ($x -lt $pad.Length -and $vowels.Contains($pad[$x])) { if ($pad[$x - 1] -ceq [char]0x2C8) { $st = 2 } elseif ($pad[$x - 1] -ceq [char]0x2CC) { $st = 1 } }
        $c = if ($w -ge 0) { $cls[$w] } else { 'B' }
        $pw = if ($w -lt 0) { 'B' } else { $f = $q -eq 0 -or $wordOf[$q - 1] -ne $w; $l = $q -eq $ph.Length - 1 -or $wordOf[$q + 1] -ne $w; if ($f -and $l) { 'S' } elseif ($f) { 'I' } elseif ($l) { 'E' } else { 'M' } }
        $pd = 'x'; $np = 'x'; $gp = 'x'; $we = 'x'; $rp = [string][int][math]::Floor(5 * $i / $n)
        if ($w -ge 0) {
            $d = 0; for ($v = $w; $v -lt $words.Count; $v++) { if ($cls[$v] -ceq 'P') { $np = $words[$v]; break }; $d++ }; $pd = [string][math]::Min(3, $d)
            $gf = $w -eq 0 -or $group[$w - 1] -ne $group[$w]; $gl = $w -eq $words.Count - 1 -or $group[$w + 1] -ne $group[$w]
            $gp = if ($gf -and $gl) { 'S' } elseif ($gf) { 'I' } elseif ($gl) { 'E' } else { 'M' }
            $we = [string][math]::Min(3, $words.Count - 1 - $w)
        }
        $k1 = [string]$sym; $k2 = "$($pad[$p-1])$sym$($pad[$p+1])"; $k3 = "$k2$($pad[$p+2])"; $k4 = "$k3|$st"; $k5 = "$k4|$c"; $k6 = "$k5|$pw"; $k7 = "$k6|$pd$np"; $k8 = "$k7|$gp$we"; $k9 = "$k8|$rp"
        $keys[$i, 0] = $k1; $keys[$i, 1] = $k2; $keys[$i, 2] = $k3; $keys[$i, 3] = $k4; $keys[$i, 4] = $k5; $keys[$i, 5] = $k6; $keys[$i, 6] = $k7; $keys[$i, 7] = $k8; $keys[$i, 8] = $k9
    }
    , $keys
}
$names = 'phone', '+L1R1', '+R2', '+stress', '+wordclass', '+posInWord', '+punct', '+group', '+sentpos'
# tables[level][key] = double[6]: sumN, cntN, sumF, cntF, sumD, cntD
$tables = foreach ($lv in 0..8) { , [Collections.Generic.Dictionary[string, double[]]]::new([StringComparer]::Ordinal) }
$sw = [Diagnostics.Stopwatch]::StartNew(); $skipped = 0
for ($s = 0; $s -lt $TrainSentences; $s++) {
    $keys = Get-Keys $order[$s].text $order[$s].phonemes; if ($null -eq $keys) { $skipped++; continue }
    $r0 = $rowOf[$s]; $n = $keys.GetLength(0); if ($rowOf[$s + 1] - $r0 -ne $n) { $skipped++; continue }
    for ($i = 0; $i -lt $n; $i++) {
        $row = $r0 + $i
        for ($lv = 0; $lv -lt 9; $lv++) {
            $acc = $null; if (-not $tables[$lv].TryGetValue($keys[$i, $lv], [ref]$acc)) { $acc = [double[]]::new(6); $tables[$lv][$keys[$i, $lv]] = $acc }
            $acc[0] += $tN[$row]; $acc[1]++; if (-not [float]::IsNaN($tF[$row])) { $acc[2] += $tF[$row]; $acc[3]++ }; $acc[4] += $tD[$row]; $acc[5]++
        }
    }
}
'trained on {0} sentences ({1} skipped as unaligned) in {2:N0} s; keys per level: {3}' -f ($TrainSentences - $skipped), $skipped, $sw.Elapsed.TotalSeconds, (($tables | ForEach-Object Count) -join ',')
function Get-Prediction($keys, [int]$i, [int]$top) {
    $pN = [double]::NaN; $pF = [double]::NaN; $pD = [double]::NaN
    for ($lv = $top; $lv -ge 0; $lv--) {
        $acc = $null; if (-not $tables[$lv].TryGetValue($keys[$i, $lv], [ref]$acc)) { continue }
        if ([double]::IsNaN($pN) -and $acc[1] -ge 5) { $pN = $acc[0] / $acc[1]; $pD = $acc[4] / $acc[5] }
        if ([double]::IsNaN($pF) -and $acc[3] -ge 5) { $pF = $acc[2] / $acc[3] }
        if (-not [double]::IsNaN($pN) -and -not [double]::IsNaN($pF)) { break }
    }
    if ([double]::IsNaN($pF)) { $pF = [math]::Log(185) }
    if ([double]::IsNaN($pN)) { $pN = 0; $pD = 3 }
    , ([double[]]@($pN, $pF, $pD))
}
# held-out RMSE per feature set (sentences TestFrom..end)
$err = [double[, ]]::new(9, 6)
for ($s = $TestFrom; $s -lt $order.Count; $s++) {
    $keys = Get-Keys $order[$s].text $order[$s].phonemes; if ($null -eq $keys) { continue }
    $r0 = $rowOf[$s]; $n = $keys.GetLength(0); if ($rowOf[$s + 1] - $r0 -ne $n) { continue }
    for ($i = 0; $i -lt $n; $i++) {
        $row = $r0 + $i
        for ($lv = 0; $lv -lt 9; $lv++) {
            $p = Get-Prediction $keys $i $lv
            $e = $p[0] - $tN[$row]; $err[$lv, 0] += $e * $e; $err[$lv, 1]++
            if (-not [float]::IsNaN($tF[$row])) { $e = $p[1] - $tF[$row]; $err[$lv, 2] += $e * $e; $err[$lv, 3]++ }
            $e = $p[2] - $tD[$row]; $err[$lv, 4] += $e * $e; $err[$lv, 5]++
        }
    }
}
'held-out tokens {0} (sentences {1}+)' -f $err[0, 1], $TestFrom
for ($lv = 0; $lv -lt 9; $lv++) { '{0,-12} RMSE N {1:N3}  logF0 {2:N4} ({3:N1} cents)  dur {4:N3} frames' -f $names[$lv], [math]::Sqrt($err[$lv, 0] / $err[$lv, 1]), [math]::Sqrt($err[$lv, 2] / $err[$lv, 3]), (1200 / [math]::Log(2) * [math]::Sqrt($err[$lv, 2] / $err[$lv, 3])), [math]::Sqrt($err[$lv, 4] / $err[$lv, 5]) }
# predictions for the nine held-out sentences at every level
$held = Get-Content $HeldOut -Raw | ConvertFrom-Json
$out = foreach ($h in $held) { $keys = Get-Keys $h.text $h.phonemes; [ordered]@{ text = $h.text; aligned = $null -ne $keys; levels = @(if ($keys) { foreach ($lv in 0..8) { , @(for ($i = 0; $i -lt $keys.GetLength(0); $i++) { , (Get-Prediction $keys $i $lv) }) } }) } }
$out | ConvertTo-Json -Depth 6 -Compress | Set-Content "$bank/prosody-predictions.json" -Encoding utf8
'elapsed {0:N0} s' -f $sw.Elapsed.TotalSeconds
