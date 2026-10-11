param([string]$Dir, [int]$Bank = 1000, [int]$Top = 3)
# Phrase-prosody donor per held-out target, from target-visible features only: vowel count, stress pattern over
# vowels, commas, final punctuation. Never compares against the target's stock tensors.
$order = Get-Content 'C:\Dev\Kokoro-Hexagon\build\unit-bank\order.json' -Raw | ConvertFrom-Json
$held = Get-Content "$Dir/heldout.json" -Raw | ConvertFrom-Json
$vowels = [Collections.Generic.HashSet[char]]::new([char[]]'aeiouæɑɒɔəɛɜɪʊʌɐᵻAEIOUWYɚɝ')
function Get-Shape([string]$ph) {
    $sb = [Text.StringBuilder]::new(); $stress = $false
    foreach ($c in $ph.ToCharArray()) {
        if ($c -eq [char]0x2C8 -or $c -eq [char]0x2CC) { $stress = $true; continue }
        if ($vowels.Contains($c)) { [void]$sb.Append($(if ($stress) { 'S' } else { 'u' })); $stress = $false }
        elseif ($c -eq ' ') { $stress = $false }
        elseif ($c -eq ',') { [void]$sb.Append('|') }
    }
    [pscustomobject]@{ Pattern = $sb.ToString(); Final = $ph[-1] }
}
function Get-Edit([string]$a, [string]$b) {
    $prev = [int[]](0..$b.Length); $cur = [int[]]::new($b.Length + 1)
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $b.Length; $j++) {
            $c = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [math]::Min([math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $c)
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    $prev[$b.Length]
}
$shapes = for ($s = 0; $s -lt $Bank; $s++) { Get-Shape $order[$s].phonemes }
$out = foreach ($h in $held) {
    $t = Get-Shape $h.phonemes
    $ranked = for ($s = 0; $s -lt $Bank; $s++) {
        $c = (Get-Edit $t.Pattern $shapes[$s].Pattern) + $(if ($t.Final -ne $shapes[$s].Final) { 5 } else { 0 })
        [pscustomobject]@{ s = $s; cost = $c }
    }
    $best = @($ranked | Sort-Object cost, s | Select-Object -First $Top)
    [ordered]@{ text = $h.text; pattern = $t.Pattern; donors = @($best | ForEach-Object { [ordered]@{ s = $_.s; cost = $_.cost; pattern = $shapes[$_.s].Pattern } }) }
}
$out | ConvertTo-Json -Depth 5 | Set-Content "$Dir/phrase-donors.json" -Encoding utf8
$out | ForEach-Object { '{0,-48} {1,-16} -> {2} (cost {3})' -f $_.text, $_.pattern, $_.donors[0].pattern, $_.donors[0].cost }
