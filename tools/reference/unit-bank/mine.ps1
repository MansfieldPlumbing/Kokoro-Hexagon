param([string]$Dir, [int[]]$Sizes = @(100, 1000, 10000, 1000000), [int]$K = 40)
# Unit selection over the bulk bank, in PowerShell. Reads build/unit-bank chunk-*.npz (npy inside zip) directly.
# Held-out targets never enter the bank. Output: selections per bank size for the stock-decoder renderer.
Add-Type -AssemblyName System.IO.Compression
$bankDir = 'C:\Dev\Kokoro-Hexagon\build\unit-bank'
$order = Get-Content "$bankDir/order.json" -Raw | ConvertFrom-Json
$held = Get-Content "$Dir/heldout.json" -Raw | ConvertFrom-Json

function Read-Npy([System.IO.Compression.ZipArchive]$zip, [string]$name) {
    $ms = [IO.MemoryStream]::new(); $s = $zip.GetEntry("$name.npy").Open(); $s.CopyTo($ms); $s.Dispose(); $b = $ms.ToArray()
    $hl = [BitConverter]::ToUInt16($b, 8); $hdr = [Text.Encoding]::ASCII.GetString($b, 10, $hl)
    $null = $hdr -match "'descr': '([^']+)'"; [pscustomobject]@{ Bytes = $b; Offset = 10 + $hl; Type = $Matches[1] }
}
function Get-Item1($a, [long]$i) {
    switch ($a.Type) {
        '<i2' { [BitConverter]::ToInt16($a.Bytes, $a.Offset + 2 * $i) }
        '<f2' { [double][BitConverter]::ToHalf($a.Bytes, [int]($a.Offset + 2 * $i)) }
        '<i8' { [BitConverter]::ToInt64($a.Bytes, $a.Offset + 8 * $i) }
        default { throw "dtype $($a.Type)" }
    }
}

# Units as parallel arrays; context index on (left, symbol, right).
$uSent = [Collections.Generic.List[int]]::new(); $uTok = [Collections.Generic.List[int]]::new(); $uDur = [Collections.Generic.List[int]]::new()
$uF0a = [Collections.Generic.List[double]]::new(); $uF0b = [Collections.Generic.List[double]]::new(); $uNa = [Collections.Generic.List[double]]::new(); $uNb = [Collections.Generic.List[double]]::new()
$pad = [Collections.Generic.List[string]]::new()
$tri = [Collections.Generic.Dictionary[string, Collections.Generic.List[int]]]::new([StringComparer]::Ordinal)
$uni = [Collections.Generic.Dictionary[char, Collections.Generic.List[int]]]::new()
function Get-Padded([string]$ph) { '##<' + $ph + '>##' }

# Learned join statistics come from genuine joins in the bank (first 1000 sentences).
$gF = [Collections.Generic.List[double]]::new(); $gN = [Collections.Generic.List[double]]::new()
$sF = $null; $sN = $null

$script:LeftW = [double[]]@(0, 4, 2, 1); $script:RightW = [double[]]@(0, 4, 2, 1)
function Get-TargetCost([string]$tp, [int]$tpos, [string]$up, [int]$upos) {
    $c = 0.0
    for ($o = 1; $o -le 3; $o++) { if ($tp[$tpos - $o] -cne $up[$upos - $o]) { $c += $script:LeftW[$o] }; if ($tp[$tpos + $o] -cne $up[$upos + $o]) { $c += $script:RightW[$o] } }
    $c
}
if ($env:KOKORO_TARGETW) { $w = [double[]]($env:KOKORO_TARGETW -split ','); $script:LeftW = [double[]]@(0) + $w[0..2]; $script:RightW = [double[]]@(0) + $w[3..5] }
function Select-Target([string]$ph) {
    $tp = Get-Padded $ph; $n = $ph.Length + 2; $cands = [object[]]::new($n); $tc = [object[]]::new($n)
    for ($t = 0; $t -lt $n; $t++) {
        $p = $t + 2; $key = $tp.Substring($p - 1, 3); $list = $null
        if (-not $tri.TryGetValue($key, [ref]$list)) { $list = $uni[$tp[$p]]; if (-not $list) { throw "No unit for symbol '$($tp[$p])'" } }
        $scored = [Collections.Generic.List[object]]::new(); $lim = [math]::Min($list.Count, 4000)
        for ($q = 0; $q -lt $lim; $q++) { $u = $list[$q]; $scored.Add([pscustomobject]@{ U = $u; C = (Get-TargetCost $tp $p $pad[$uSent[$u]] ($uTok[$u] + 2)) }) }
        $best = @($scored | Sort-Object C | Select-Object -First $K)
        $cands[$t] = [int[]]@($best.U); $tc[$t] = [double[]]@($best.C)
    }
    $cost = [object[]]::new($n); $back = [object[]]::new($n); $cost[0] = $tc[0]
    for ($t = 1; $t -lt $n; $t++) {
        $prev = $cands[$t - 1]; $cur = $cands[$t]; $row = [double[]]::new($cur.Count); $bp = [int[]]::new($cur.Count)
        for ($j = 0; $j -lt $cur.Count; $j++) {
            $b = $cur[$j]; $best = [double]::MaxValue; $arg = 0
            for ($i = 0; $i -lt $prev.Count; $i++) {
                $a = $prev[$i]
                if ($uSent[$a] -eq $uSent[$b] -and $uTok[$b] -eq $uTok[$a] + 1) { $jc = 0.0 }
                else {
                    $z = ($uNa[$b] - $uNb[$a] - $sN.m) / $sN.s; $jc = 0.5 * $z * $z
                    $va = $uF0b[$a] -gt 10; $vb = $uF0a[$b] -gt 10
                    if ($va -and $vb) { $z = ([math]::Log($uF0a[$b]) - [math]::Log($uF0b[$a]) - $sF.m) / $sF.s; $jc += 0.5 * $z * $z } elseif ($va -ne $vb) { $jc += 2.0 }
                }
                $c = $cost[$t - 1][$i] + $jc; if ($c -lt $best) { $best = $c; $arg = $i }
            }
            $row[$j] = $best + $tc[$t][$j]; $bp[$j] = $arg
        }
        $cost[$t] = $row; $back[$t] = $bp
    }
    $last = $cost[$n - 1]; $j = [array]::IndexOf($last, ($last | Measure-Object -Minimum).Minimum); $path = [object[]]::new($n)
    for ($t = $n - 1; $t -ge 0; $t--) { $u = $cands[$t][$j]; $path[$t] = [ordered]@{ s = $uSent[$u]; i = $uTok[$u] }; if ($t) { $j = $back[$t][$j] } }
    $runs = 1; for ($t = 1; $t -lt $n; $t++) { if (-not ($path[$t].s -eq $path[$t - 1].s -and $path[$t].i -eq $path[$t - 1].i + 1)) { $runs++ } }
    [pscustomobject]@{ Path = $path; Runs = $runs }
}

$results = [ordered]@{}; $sizeIdx = 0; $sw = [Diagnostics.Stopwatch]::StartNew(); $sent = 0
$chunks = Get-ChildItem $bankDir -Filter 'chunk-*.npz' | Sort-Object Name
foreach ($cf in $chunks) {
    if ($sizeIdx -ge $Sizes.Count) { break }
    $zip =[IO.Compression.ZipFile]::OpenRead($cf.FullName)
    $dur = Read-Npy $zip 'dur'; $f0 = Read-Npy $zip 'f0'; $nn = Read-Npy $zip 'n'; $to = Read-Npy $zip 'tok_off'; $fo = Read-Npy $zip 'frm_off'; $zip.Dispose()
    $base = [int]($cf.BaseName.Substring(6)) * 1000; $count = ($to.Bytes.Length - $to.Offset) / 8 - 1
    for ($ls = 0; $ls -lt $count; $ls++) {
        $s = $base + $ls; $ph = $order[$s].phonemes; $pad.Add((Get-Padded $ph)) | Out-Null
        $t0 = Get-Item1 $to $ls; $t1 = Get-Item1 $to ($ls + 1); $frame = Get-Item1 $fo $ls
        $padded = $pad[$s]
        for ($i = 0; $i -lt $t1 - $t0; $i++) {
            $d = Get-Item1 $dur ($t0 + $i); $h0 = 2 * $frame; $h1 = 2 * ($frame + $d) - 1; $frame += $d
            $u = $uSent.Count
            $uSent.Add($s); $uTok.Add($i); $uDur.Add($d)
            $uF0a.Add((Get-Item1 $f0 $h0)); $uF0b.Add((Get-Item1 $f0 $h1)); $uNa.Add((Get-Item1 $nn $h0)); $uNb.Add((Get-Item1 $nn $h1))
            $key = $padded.Substring($i + 1, 3); $list = $null
            if (-not $tri.TryGetValue($key, [ref]$list)) { $list = [Collections.Generic.List[int]]::new(); $tri[$key] = $list }; $list.Add($u)
            $sym = $padded[$i + 2]; if (-not $uni.ContainsKey($sym)) { $uni[$sym] = [Collections.Generic.List[int]]::new() }; $uni[$sym].Add($u)
            if ($i -gt 0 -and $s -lt 1000) {
                $a = $u - 1; $gN.Add($uNa[$u] - $uNb[$a]); if ($uF0b[$a] -gt 10 -and $uF0a[$u] -gt 10) { $gF.Add([math]::Log($uF0a[$u]) - [math]::Log($uF0b[$a])) }
            }
        }
        $sent++
        if ($sent -eq 1000 -or ($null -eq $sF -and $sent -eq $order.Count)) {
            $m = ($gF | Measure-Object -Average).Average; $sF = @{ m = $m; s = [math]::Sqrt((($gF | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Average).Average) }
            $m = ($gN | Measure-Object -Average).Average; $sN = @{ m = $m; s = [math]::Sqrt((($gN | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Average).Average) }
        }
        $isLast = ($cf -eq $chunks[-1] -and $ls -eq $count - 1)
        while ($sizeIdx -lt $Sizes.Count -and ($sent -eq $Sizes[$sizeIdx] -or ($isLast -and $sent -lt $Sizes[$sizeIdx]))) {
            if ($null -eq $sF) { $sF = @{ m = 0.0; s = 0.27 }; $sN = @{ m = 0.0; s = 0.9 } }
            $st = [Diagnostics.Stopwatch]::StartNew()
            $sel = foreach ($h in $held) { $r = Select-Target $h.phonemes; [ordered]@{ text = $h.text; runs = $r.Runs; path = $r.Path } }
            $results["$sent"] = [ordered]@{ sentences = $sent; units = $uSent.Count; contexts = $tri.Count; selectMs = $st.Elapsed.TotalMilliseconds; picks = @($sel) }
            "bank {0} sentences, {1} units, {2} (L,sym,R) contexts; selection {3:N1} s for {4} targets; runs {5}; elapsed {6:N0} s" -f $sent, $uSent.Count, $tri.Count, $st.Elapsed.TotalSeconds, @($held).Count, (($sel | ForEach-Object runs) -join ','), $sw.Elapsed.TotalSeconds
            $sizeIdx++
            if ($isLast) { break }
        }
    }
}
$results | ConvertTo-Json -Depth 6 | Set-Content "$Dir/big-selections.json" -Encoding utf8
