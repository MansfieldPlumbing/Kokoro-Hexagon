param([string[]]$In, [string]$Out)
# Rejected sentences and their reasons (OOV words, grammar/pronunciation status) for the phonemizer coverage campaign.
$dll = Get-ChildItem C:\Dev\Kokoro-Hexagon\build\phonemizer\english\driver -Recurse -Filter 'Dev.MansfieldPlumbing.English.Driver.*.dll' | Sort-Object LastWriteTime | Select-Object -Last 1
$type = [Reflection.Assembly]::LoadFrom($dll.FullName).GetType('CoreDriver', $true)
$run = [Func[string, object]]$type.GetMethod('Run').CreateDelegate([Func[string, object]])
$oov = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase); $status = @{}
$rej = foreach ($f in $In) { foreach ($t in (Get-Content $f -Raw | ConvertFrom-Json)) {
    $r = $run.Invoke($t); if ([string]$r.KokoroPhones) { continue }
    $words = @($r.OovSpans | ForEach-Object Word)
    foreach ($w in $words) { $oov[$w] = 1 + $(if ($oov.ContainsKey($w)) { $oov[$w] } else { 0 }) }
    $k = "$($r.GrammarStatus)/$($r.PronunciationStatus)"; $status[$k] = 1 + [int]$status[$k]
    [pscustomobject]@{ text = $t; grammar = [string]$r.GrammarStatus; pronunciation = [string]$r.PronunciationStatus; oov = $words }
} }
[ordered]@{ rejected = @($rej); oovCounts = ($oov.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [ordered]@{ word = $_.Key; count = $_.Value } }) } | ConvertTo-Json -Depth 4 | Set-Content $Out -Encoding utf8
'{0} rejected; {1} distinct OOV words; with no OOV word: {2}' -f @($rej).Count, $oov.Count, @($rej | Where-Object { -not $_.oov }).Count
$status.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { '  {0}: {1}' -f $_.Key, $_.Value }
'top OOV: ' + (($oov.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25 | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')
