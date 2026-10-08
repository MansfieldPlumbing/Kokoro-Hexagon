#requires -Version 7.0
# Device harness for the compiled phonemizer driver (phonemizer/Invoke-EnglishPhonemizer.ps1 -BuildDriver).
# Loads the CoreLib-only driver from its path, phonemizes each line of sentences.txt with CoreDriver.Run,
# and records the Kokoro symbol IDs, the cold load/first-call times and the warm median per sentence.
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl')
$dir = [IO.Path]::Combine($root, 'phonemizer')
$receipt = [IO.Path]::Combine($dir, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=kokoro-phonemizer')
$inv = [Globalization.CultureInfo]::InvariantCulture
$passed = $false
try {
    $dll = [IO.Path]::Combine($dir, 'driver.dll')
    $lines.Add('DriverSHA256=' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($dll))))
    $sentences = [IO.File]::ReadAllLines([IO.Path]::Combine($dir, 'sentences.txt'), [Text.UTF8Encoding]::new($false, $true))
    if ($sentences.Count -lt 1 -or $sentences.Count -gt 512) { throw 'Sentence count out of range' }
    foreach ($s in $sentences) { if ($s.Length -lt 1 -or $s.Length -gt 2048) { throw 'Sentence length out of range' } }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $assembly = [Reflection.Assembly]::LoadFrom($dll)
    $type = $assembly.GetType('CoreDriver', $true)
    $runMethod = $type.GetMethod('Run')
    $lines.Add('LoadMs=' + $watch.Elapsed.TotalMilliseconds.ToString('F3', $inv))
    $watch.Restart()
    $first = $runMethod.Invoke($null, [object[]]@($sentences[0]))
    $lines.Add('FirstRunMs=' + $watch.Elapsed.TotalMilliseconds.ToString('F3', $inv))
    $complete = 0; $all = [Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $sentences.Count; $i++) {
        for ($w = 0; $w -lt 5; $w++) { $null = $runMethod.Invoke($null, [object[]]@($sentences[$i])) }
        $samples = [double[]]::new(25)
        for ($r = 0; $r -lt 25; $r++) {
            $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
            $result = $runMethod.Invoke($null, [object[]]@($sentences[$i]))
            $samples[$r] = ([Diagnostics.Stopwatch]::GetTimestamp() - $t0) * 1e6 / [Diagnostics.Stopwatch]::Frequency
        }
        [Array]::Sort($samples); $all.Add($samples[12])
        $ids = if ($result.Complete) { $result.SymbolIds -join ',' } else { '' }
        if ($result.Complete) { $complete++ }
        $lines.Add("S$i Complete=$($result.Complete) MedianUs=$($samples[12].ToString('F1', $inv)) Ids=$ids")
    }
    $sorted = $all.ToArray(); [Array]::Sort($sorted)
    $lines.Add("Sentences=$($sentences.Count) Complete=$complete MedianOfMediansUs=$($sorted[[int]($sorted.Length / 2)].ToString('F1', $inv))")
    $passed = $true
}
catch { $lines.Add('Error=' + $_.Exception.ToString().Replace("`n", ' ')) }
finally {
    $lines.Add("Passed=$passed")
    [IO.File]::WriteAllLines($receipt, $lines.ToArray())
}
