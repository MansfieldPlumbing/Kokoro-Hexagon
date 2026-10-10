param([string[]]$In, [string]$Out)
# Phonemize through the lowered CoreDriver DLL directly (newest build), one process for the whole corpus.
$dll = Get-ChildItem C:\Dev\Kokoro-Hexagon\build\phonemizer\english\driver -Recurse -Filter 'Dev.MansfieldPlumbing.English.Driver.*.dll' | Sort-Object LastWriteTime | Select-Object -Last 1
$type = [Reflection.Assembly]::LoadFrom($dll.FullName).GetType('CoreDriver', $true)
$run = [Func[string, object]]$type.GetMethod('Run').CreateDelegate([Func[string, object]])
$texts = foreach ($f in $In) { Get-Content $f -Raw | ConvertFrom-Json }
$sw = [Diagnostics.Stopwatch]::StartNew(); $failed = 0
$rows = foreach ($t in $texts) {
    try { $r = $run.Invoke($t); $ph = ([string]$r.KokoroPhones -replace ' ([.,?!;])', '$1').Trim() } catch { $ph = '' }
    if ($ph.Length -lt 2 -or $ph.Length -gt 400) { $failed++; continue }
    [pscustomobject]@{ text = $t; phonemes = $ph }
}
$rows | ConvertTo-Json | Set-Content $Out -Encoding utf8
'{0} phonemized, {1} rejected, {2:N1} s ({3})' -f @($rows).Count, $failed, $sw.Elapsed.TotalSeconds, $dll.Name
