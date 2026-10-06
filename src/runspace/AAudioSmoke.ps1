#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::Combine($Activity.FilesDir.AbsolutePath, 'kokoro-fl', 'aaudio-smoke')
$receipt = [IO.Path]::Combine($root, 'receipt.txt')
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('Job=aaudio-native-binding-smoke')
$stream = $null
$audio = $null
try {
    $load = {
        param([string]$Name, [object[]]$Arguments)
        $path = [IO.Path]::Combine($root, $Name)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "$Name did not parse." }
        $ast.GetScriptBlock().InvokeReturnAsIs($Arguments)
    }
    $binding = & $load 'Native.Binding.psm1' @()
    $audio = & $load 'Audio.AAudio.psm1' @($binding)
    $stream = & $audio.Open 24000 1
    [float[]]$samples = [float[]]::new(6000)
    for ($i = 0; $i -lt $samples.Length; $i++) {
        $envelope = [Math]::Min(1.0, [Math]::Min($i, $samples.Length - 1 - $i) / 240.0)
        $samples[$i] = [float](0.035 * $envelope * [Math]::Sin(2.0 * [Math]::PI * 440.0 * $i / 24000.0))
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $written = & $audio.Write $stream $samples $clock
    $drain = & $audio.Drain $stream 5000
    $lines.Add("Rate=$($stream.SampleRate)")
    $lines.Add("Channels=$($stream.Channels)")
    $lines.Add("FramesWritten=$written")
    $lines.Add("FramesRead=$($drain.FramesRead)")
    $lines.Add("XRunCount=$($drain.XRunCount)")
    $lines.Add("DrainComplete=$($drain.Complete)")
    if ($written -ne $samples.Length -or -not $drain.Complete) { throw 'AAudio smoke did not drain every frame.' }
    $lines.Add('Passed=True')
}
catch {
    $lines.Add('Passed=False')
    $lines.Add('Error=' + $_.Exception.Message)
}
finally {
    if ($null -ne $stream -and $null -ne $audio) {
        try { $lines.Add("CloseRc=$(& $audio.Close $stream)") } catch { $lines.Add('CloseFailed=True') }
    }
    [IO.File]::WriteAllLines($receipt, $lines)
}
[void][Android.Util.Log]::Info('KokoroAAudio', ($lines -join ' | '))
