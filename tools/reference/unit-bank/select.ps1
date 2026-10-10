param([string]$Dir)
# Unit selection over the stock-Kokoro donor bank: arbitrary, context-matched, and Viterbi with a join cost learned from
# the bank's own genuine (adjacent-in-donor) joins. Uses only the target phoneme string, never target tensors.
$bank = Get-Content "$Dir/bank.json" -Raw | ConvertFrom-Json
$units = $bank.units
$target = @('<s>') + @($bank.target.ToCharArray() | ForEach-Object { [string]$_ }) + @('</s>')
$bySym = @{}
foreach ($u in $units) { if (-not $bySym.ContainsKey($u.sym)) { $bySym[$u.sym] = [System.Collections.Generic.List[object]]::new() }; $bySym[$u.sym].Add($u) }
$missing = @($target | Where-Object { -not $bySym.ContainsKey($_) } | Select-Object -Unique)
if ($missing) { throw "No donor unit for: $($missing -join ' ')" }

# Learn the join model from genuine joins: log-F0 step (both sides voiced) and N step at the boundary half-frames.
$key = @{}; foreach ($u in $units) { $key["$($u.s)/$($u.i)"] = $u }
$dF = [System.Collections.Generic.List[double]]::new(); $dN = [System.Collections.Generic.List[double]]::new()
foreach ($u in $units) {
    $v = $key["$($u.s)/$($u.i + 1)"]; if (-not $v) { continue }
    $dN.Add($v.n[0] - $u.n[-1])
    if ($u.f0[-1] -gt 10 -and $v.f0[0] -gt 10) { $dF.Add([math]::Log($v.f0[0]) - [math]::Log($u.f0[-1])) }
}
function Get-Stat($x) { $m = ($x | Measure-Object -Average).Average; $sd = [math]::Sqrt((($x | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Average).Average); @{ m = $m; s = [math]::Max($sd, 1e-3) } }
$sF = Get-Stat $dF; $sN = Get-Stat $dN
function Get-JoinCost($a, $b) {
    if ($a.s -eq $b.s -and $b.i -eq $a.i + 1) { return 0.0 }
    $z = ($b.n[0] - $a.n[-1] - $sN.m) / $sN.s; $c = 0.5 * $z * $z
    if ($a.f0[-1] -gt 10 -and $b.f0[0] -gt 10) { $z = ([math]::Log($b.f0[0]) - [math]::Log($a.f0[-1]) - $sF.m) / $sF.s; $c += 0.5 * $z * $z }
    elseif (($a.f0[-1] -gt 10) -ne ($b.f0[0] -gt 10)) { $c += 2.0 }  # voicing change across a non-genuine join
    $c
}
$script:Width = 1; $script:Weights = @(0, 1.0, 1.0, 1.0)  # weight per offset; Width 1 = immediate neighbours only
function Get-TargetCost($u, $t) {
    $c = 0.0
    for ($o = 1; $o -le $script:Width; $o++) {
        foreach ($sg in -1, 1) {
            $tt = $t + $sg * $o; $ts = if ($tt -ge 0 -and $tt -lt $target.Count) { $target[$tt] } else { '' }
            $n = $key["$($u.s)/$($u.i + $sg * $o)"]; $us = if ($n) { $n.sym } else { '' }
            if ($us -ne $ts) { $c += $script:Weights[$o] }
        }
    }
    $c
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rng = [System.Random]::new(1)
$arbitrary = foreach ($t in 0..($target.Count - 1)) { $c = $bySym[$target[$t]]; $c[$rng.Next($c.Count)] }
$context = foreach ($t in 0..($target.Count - 1)) { $bySym[$target[$t]] | Sort-Object { Get-TargetCost $_ $t } | Select-Object -First 1 }

# Viterbi: target cost (context mismatches) + learned join cost.
$cands = foreach ($t in 0..($target.Count - 1)) { , @($bySym[$target[$t]]) }
function Invoke-Viterbi {
$cost = @(, @($cands[0] | ForEach-Object { Get-TargetCost $_ 0 })); $back = @(, @())
foreach ($t in 1..($target.Count - 1)) {
    $row = [double[]]::new($cands[$t].Count); $bp = [int[]]::new($cands[$t].Count)
    for ($j = 0; $j -lt $cands[$t].Count; $j++) {
        $best = [double]::MaxValue; $arg = 0
        for ($i = 0; $i -lt $cands[$t - 1].Count; $i++) { $c = $cost[$t - 1][$i] + (Get-JoinCost $cands[$t - 1][$i] $cands[$t][$j]); if ($c -lt $best) { $best = $c; $arg = $i } }
        $row[$j] = $best + (Get-TargetCost $cands[$t][$j] $t); $bp[$j] = $arg
    }
    $cost += , $row; $back += , $bp
}
$j = [array]::IndexOf($cost[-1], ($cost[-1] | Measure-Object -Minimum).Minimum); $path = [object[]]::new($target.Count)
for ($t = $target.Count - 1; $t -ge 0; $t--) { $path[$t] = $cands[$t][$j]; if ($t) { $j = $back[$t][$j] } }
, $path
}
$path = Invoke-Viterbi
# Wide context: the donor t_en column depends on several tokens either side (text encoder convs and BiLSTM), so match
# +-3 tokens, nearest weighted most, and weight context above the join cost.
$script:Width = 3; $script:Weights = @(0, 4.0, 2.0, 1.0)
$wide = Invoke-Viterbi
$sw.Stop()

$pick = { param($list) @($list | ForEach-Object { [ordered]@{ s = $_.s; i = $_.i } }) }
[ordered]@{ arbitrary = & $pick $arbitrary; context = & $pick $context; learned = & $pick $path; wide = & $pick $wide } | ConvertTo-Json -Depth 4 | Set-Content "$Dir/selections.json" -Encoding utf8
'wide path donors: ' + (($wide | ForEach-Object { '{0}{1}' -f $_.sym, $_.s }) -join ' ')
function Get-Runs($p) { $r = 1; for ($k = 1; $k -lt $p.Count; $k++) { if (-not ($p[$k].s -eq $p[$k - 1].s -and $p[$k].i -eq $p[$k - 1].i + 1)) { $r++ } }; $r }
'target tokens {0}; candidates per token min/avg {1}/{2:N1}; genuine joins {3} (dlogF0 sd {4:N3}, dN sd {5:N3})' -f $target.Count, ($cands | ForEach-Object Count | Measure-Object -Minimum).Minimum, ($cands | ForEach-Object Count | Measure-Object -Average).Average, $dN.Count, $sF.s, $sN.s
'segments (donor runs): arbitrary {0}, context {1}, learned {2}; selection time {3:N0} ms (interpreted)' -f (Get-Runs $arbitrary), (Get-Runs $context), (Get-Runs $path), $sw.Elapsed.TotalMilliseconds
'learned path donors: ' + (($path | ForEach-Object { '{0}{1}' -f $_.sym, $_.s }) -join ' ')
