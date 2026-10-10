using module C:\Dev\PSPerception\Dev.MansfieldPlumbing.PowerShell.Perception.psd1
param([string]$Dir, [int]$Donors = 300, [int]$TokensPerDonor = 2, [int]$CandidatesPerToken = 2)
# Resident loop: verified t_en substitutions (stock decoder evaluator over a pipe) -> PSPerception refine -> held-out
# check of the learned projection. Bank = sentences 0-999; donors (dev) = sentences 1000+.
Set-StrictMode -Off
Add-Type -AssemblyName System.IO.Compression
$bankDir = 'C:\Dev\Kokoro-Hexagon\build\unit-bank'
$order = Get-Content "$bankDir/order.json" -Raw | ConvertFrom-Json
$K = [Reflection.Assembly]::LoadFile("$bankDir\kernels\Dev.MansfieldPlumbing.Kokoro.UnitKernels.dll").GetType('UnitKernels')

# --- token features from the phoneme string (BOS '<', EOS '>') ---
$vowels = [Collections.Generic.HashSet[char]]::new([char[]]'aeiouæɑɒɔəɛɜɪʊʌɐᵻAEIOUWYɚɝ')
function Get-Class([char]$c) {
    if ($c -eq '#') { 'edge' } elseif ($c -eq '<' -or $c -eq '>') { 'bound' } elseif ($c -eq ' ') { 'space' }
    elseif ($c -eq [char]0x2C8 -or $c -eq [char]0x2CC) { 'stress' } elseif ('.,!?;:'.Contains($c)) { 'punct' }
    elseif ($vowels.Contains($c)) { 'vowel' } else { 'cons' }
}
class TokenContext { [string]$Pad; [int]$Pos; [int]$Stressed; [int]$WordPos; [int]$PhraseEnd }
function Get-TokenContext([string]$ph, [int]$i) {
    $pad = '###<' + $ph + '>###'; $p = $i + 3
    # stressed: the next vowel at or after p in this word is directly preceded by a stress mark
    $q = $p; $st = 0
    while ($q -lt $pad.Length -and $pad[$q] -ne ' ' -and -not $vowels.Contains($pad[$q])) { $q++ }
    if ($q -lt $pad.Length -and $vowels.Contains($pad[$q]) -and ($pad[$q - 1] -eq [char]0x2C8 -or $pad[$q - 1] -eq [char]0x2CC)) { $st = 1 }
    $l = $pad[$p - 1]; $r = $pad[$p + 1]
    $wp = if ((Get-Class $l) -in 'space', 'bound') { 0 } elseif ((Get-Class $r) -in 'space', 'bound', 'punct') { 2 } else { 1 }
    $pe = 0; for ($o = 1; $o -le 3; $o++) { if ((Get-Class $pad[$p + $o]) -in 'punct', 'bound') { $pe = 1 } }
    [TokenContext]@{ Pad = $pad; Pos = $p; Stressed = $st; WordPos = $wp; PhraseEnd = $pe }
}
function Get-Agreement([TokenContext]$a, [TokenContext]$b) {
    $sym = { param($x, $o) $x.Pad[$x.Pos + $o] }
    [pscustomobject]@{
        L2 = [int]((& $sym $a -2) -eq (& $sym $b -2)); R2 = [int]((& $sym $a 2) -eq (& $sym $b 2))
        L3 = [int]((& $sym $a -3) -eq (& $sym $b -3)); R3 = [int]((& $sym $a 3) -eq (& $sym $b 3))
        L2c = [int]((Get-Class (& $sym $a -2)) -eq (Get-Class (& $sym $b -2))); R2c = [int]((Get-Class (& $sym $a 2)) -eq (Get-Class (& $sym $b 2)))
        Stress = [int]($a.Stressed -eq $b.Stressed); WordPos = [int]($a.WordPos -eq $b.WordPos); PhraseEnd = [int]($a.PhraseEnd -eq $b.PhraseEnd)
    }
}

# --- bank index: (L, sym, R) -> list of (s, i) over sentences 0-999 ---
$tri = [Collections.Generic.Dictionary[string, Collections.Generic.List[int[]]]]::new([StringComparer]::Ordinal)
for ($s = 0; $s -lt 1000; $s++) {
    $pad = '#<' + $order[$s].phonemes + '>#'
    for ($i = 0; $i -lt $pad.Length - 2; $i++) {
        $key = $pad.Substring($i, 3); $list = $null
        if (-not $tri.TryGetValue($key, [ref]$list)) { $list = [Collections.Generic.List[int[]]]::new(); $tri[$key] = $list }
        $list.Add([int[]]@($s, $i))
    }
}

# --- resident evaluator ---
$psi = [Diagnostics.ProcessStartInfo]::new('C:/bin/micromamba/envs/mono/python.exe', "-I `"$Dir/eval_server.py`"")
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
$psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false); $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
$eval = [Diagnostics.Process]::Start($psi)
function Invoke-Swap($s, $i, $rs, $ri) {
    $eval.StandardInput.WriteLine((@{ op = 'swap'; s = $s; i = $i; rs = $rs; ri = $ri } | ConvertTo-Json -Compress)); $eval.StandardInput.Flush()
    $eval.StandardOutput.ReadLine() | ConvertFrom-Json
}

# --- verified observations ---
$rng = [Random]::new(11); $obs = [Collections.Generic.List[object]]::new(); $sw = [Diagnostics.Stopwatch]::StartNew()
$donorIds = @(1000..($order.Count - 1) | Where-Object { $order[$_].phonemes.Length -le 40 } | Select-Object -First $Donors)
foreach ($s in $donorIds) {
    $ph = $order[$s].phonemes; $pad = '#<' + $ph + '>#'
    $phoneTok = @(1..$ph.Length | Where-Object { (Get-Class $pad[$_ + 1 - 1 + 1]) -in 'vowel', 'cons' })
    foreach ($i in @($phoneTok | Sort-Object { $rng.Next() } | Select-Object -First $TokensPerDonor)) {
        $key = $pad.Substring($i, 3); $list = $null
        if (-not $tri.TryGetValue($key, [ref]$list) -or $list.Count -lt 2) { continue }
        $ctxA = Get-TokenContext $ph $i
        for ($c = 0; $c -lt $CandidatesPerToken; $c++) {
            $pick = $list[$rng.Next($list.Count)]
            $r = Invoke-Swap $s $i $pick[0] $pick[1]
            if (-not $r.ok) { Write-Warning $r.error; continue }
            $ctxB = Get-TokenContext $order[$pick[0]].phonemes $pick[1]
            $obs.Add([pscustomobject]@{ s = $s; i = $i; rs = $pick[0]; ri = $pick[1]; sym = [string]$pad[$i + 1]; local = [double]$r.local; agree = (Get-Agreement $ctxA $ctxB) })
        }
    }
    if ($obs.Count % 50 -lt $CandidatesPerToken) { '{0} observations, {1:N0} s' -f $obs.Count, $sw.Elapsed.TotalSeconds }
}
$eval.StandardInput.Close(); $eval.WaitForExit(10000) | Out-Null
$obs | ConvertTo-Json -Depth 4 | Set-Content "$bankDir/refine-observations.json" -Encoding utf8

# --- outcome threshold, split by donor sentence, refine ---
$tau = ($obs.local | Sort-Object)[[int]($obs.Count / 2)]
$split = [Collections.Generic.HashSet[int]]::new([int[]]@($donorIds | Where-Object { $_ % 3 -eq 0 }))
$toRecord = { param($o) New-ObservationRecord -RepresentationVersion 'acoustic-v0' -CanonicalBefore $o.agree -RepresentedBefore @{} -Action $o.sym -PredictedDelta 0 -ActualDelta ([int]($o.local -lt $tau)) -PredictionError 0 -ConditionKey '' }
$train = @($obs | Where-Object { -not $split.Contains($_.s) } | ForEach-Object { & $toRecord $_ })
$test = @($obs | Where-Object { $split.Contains($_.s) })
'observations {0} (train {1}, held-out {2}); tau (median local distance) {3:N3}; local min/median/max {4:N2}/{3:N2}/{5:N2}' -f $obs.Count, $train.Count, $test.Count, $tau, ($obs.local | Measure-Object -Minimum).Minimum, ($obs.local | Measure-Object -Maximum).Maximum
$store = $null
$result = Invoke-PerceptRefine -Experience $train -MaxIterations 10 -MaxAdmissions 4
'refine result properties: ' + (($result.PSObject.Properties | ForEach-Object Name) -join ', ')
$rep = foreach ($n in 'Representation', 'FinalRepresentation', 'CurrentRepresentation') { if ($result.PSObject.Properties[$n]) { $result.$n } }
if (-not $rep -and $result.PSObject.Properties['Store']) { $rep = $result.Store.Current.Representation }
$features = @($rep | ForEach-Object { $_.Features })
'learned features: ' + ($features -join ', ')

# --- held-out check: majority outcome per (phone + features) learned on train vs phone-only baseline ---
function Test-Projection([string[]]$f) {
    $tab = @{}
    foreach ($o in ($obs | Where-Object { -not $split.Contains($_.s) })) { $k = $o.sym + '|' + (($f | ForEach-Object { $o.agree.$_ }) -join ''); if (-not $tab[$k]) { $tab[$k] = [int[]]@(0, 0) }; $tab[$k][[int]($o.local -lt $tau)]++ }
    $hit = 0; $n = 0
    foreach ($o in $test) { $k = $o.sym + '|' + (($f | ForEach-Object { $o.agree.$_ }) -join ''); if ($tab[$k]) { $n++; $pred = [int]($tab[$k][1] -ge $tab[$k][0]); if ($pred -eq [int]($o.local -lt $tau)) { $hit++ } } }
    '{0,-40} held-out accuracy {1:P1} over {2} covered' -f ($(if ($f) { $f -join '+' } else { '(phone only)' })), ($hit / [math]::Max(1, $n)), $n
}
Test-Projection @()
foreach ($one in 'L2', 'R2', 'L3', 'R3', 'L2c', 'R2c', 'Stress', 'WordPos', 'PhraseEnd') { Test-Projection @($one) }
if ($features) { Test-Projection $features }
$result | Select-Object -ExcludeProperty Store | ConvertTo-Json -Depth 3 | Set-Content "$bankDir/refine-result.json" -Encoding utf8
