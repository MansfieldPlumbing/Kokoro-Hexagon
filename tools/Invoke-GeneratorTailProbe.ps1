#requires -Version 7.4
<#
.SYNOPSIS
Runs the emitted generator tail job on an attached phone, plays its PCM, and retrieves the output.

.DESCRIPTION
Stages the skel, harness, Native.Binding.psm1, Audio.AAudio.psm1 and the tail fixture into the
host app's private storage (hash-checked), runs the harness as the app's startup script, pulls
run 0's output buffer back (hash-checked against the receipt), then restores the startup scripts
and any replaced file and verifies the restore by hash (or restores original absence).
The phone is selected by ro.soc.model;
no serial is printed. Check the retrieved buffer with tools/Test-KokoroGeneratorTailOutput.ps1.
#>
param(
    [Parameter(Mandatory)][string] $EmissionDirectory,
    [Parameter(Mandatory)][string] $FixtureDirectory,
    [ValidateRange(1, 121)][int] $Runs = 3,
    [ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
    # The pinned PowerShell ADB client (Kokoro.Evaluator.psm1 Get-KokoroAdbClient), called with -Api.
    [Parameter(Mandatory)][string] $Adb,
    [string] $Package = 'dev.mansfieldplumbing.kokoro',
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 180,
    [pscustomobject] $EmissionArtifact,
    [ValidatePattern('^[0-9A-F]{64}$')][string] $ExpectedPcmSHA256,
    [switch] $AttributeBuffers,
    [switch] $ResidentPayloads,
    [switch] $RequestLifetime,
    # Start the resident job listener (src/runspace/KokoroGeneratorTailProbe.ps1 Serve mode) instead of one job: wait
    # for Listening=, then restore the startup files without stopping the app, which keeps serving from memory.
    [switch] $Serve,
    # Text to WAV in the app's runspace (src/runspace/KokoroGeneratorTailProbe.ps1 speech mode) with this job's library as the
    # generator: -StageFiles maps each further file's path under the app's files directory to its local path
    # (Invoke-KokoroPhoneSpeech). The WAV is fetched beside the receipt.
    [switch] $Speech,
    [hashtable] $StageFiles = @{},
    [pscustomobject] $WeightAssembly
)
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid Android package name' }
$emission = [IO.Path]::GetFullPath($EmissionDirectory); $fixture = [IO.Path]::GetFullPath($FixtureDirectory)
$library = Join-Path $emission 'libkokoro_generator_tail_skel.so'
if ($null -ne $EmissionArtifact) {
    if ($null -eq $EmissionArtifact.Layout -or
        [IO.Path]::GetFullPath($EmissionArtifact.Directory) -cne $emission -or
        [IO.Path]::GetFullPath($EmissionArtifact.Path) -cne $library -or
        (Get-Item -LiteralPath $library).Length -ne $EmissionArtifact.Bytes -or
        (Get-FileHash -LiteralPath $library).Hash -cne $EmissionArtifact.LibrarySHA256) {
        throw 'Typed emission identity or library integrity mismatch.'
    }
    $layout = $EmissionArtifact.Layout
} else {
    # Preserved reference artifacts retain their original metadata contract.
    $layout = Get-Content (Join-Path $emission 'runner-layout.json') -Raw | ConvertFrom-Json
}
if ([long]$layout.Tiles -lt 1 -or [long]$layout.Tiles -gt 32768 -or
    [long]$layout.InputBytes -lt 1 -or [long]$layout.Samples -lt 1 -or
    [long]$layout.PcmOffset -lt 0 -or
    [long]$layout.PcmOffset + 2L * [long]$layout.Samples -gt [long]$layout.OutputBytes) {
    throw 'Runner layout is out of range.'
}
if ([IO.Path]::GetFileName($Adb) -cne 'adb.ps1' -or -not (Test-Path -LiteralPath $Adb)) { throw 'Pass -Adb, the pinned PowerShell ADB client (Get-KokoroAdbClient).' }
$serials = @(& $Adb devices -Api | Where-Object { $_.IsAccessible -or $_.Connected } | ForEach-Object { [string]$_.Index } |
    Where-Object { ([string](& $Adb shell -Api -Device $_ 'getprop ro.soc.model').Stdout).Trim() -eq $Soc })
if ($serials.Count -ne 1) { throw "Expected exactly one attached $Soc device, found $($serials.Count)." }
$serial = $serials[0]
# push copies a file; every other operation is one device shell command, sent as a single string so its flags never
# bind to adb.ps1 parameters. Returns the command's output lines.
$run = { param([string[]]$Arguments)
    if ($Arguments[0] -ceq 'push') { $null = & $Adb push -Api -Device $serial $Arguments[1] $Arguments[2]; return }
    $words = if ($Arguments[0] -ceq 'shell') { @($Arguments | Select-Object -Skip 1) } else { $Arguments }
    $result = & $Adb shell -Api -Device $serial ($words -join ' ')
    if ([int]$result.ExitCode) { throw "Device operation failed: $($Arguments[0]) $($Arguments[1])" }
    ([string]$result.Stdout) -split "`r?`n" }
$harness = Join-Path $PSScriptRoot '..\src\runspace\KokoroGeneratorTailProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
$aaudio = Join-Path $PSScriptRoot '..\src\runspace\Audio.AAudio.psm1'
foreach ($p in $harness, $binding, $aaudio) { $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); if ($e.Count) { throw "Does not parse: $p" } }
$id = [Guid]::NewGuid().ToString('N')
$spec = Join-Path $emission "tail-spec-$id.txt"
[IO.File]::WriteAllLines($spec, @("Tiles=$($layout.Tiles)", "Runs=$Runs", "OutputBytes=$($layout.OutputBytes)", "PcmOffset=$($layout.PcmOffset)", "Samples=$($layout.Samples)", "InputBytes=$($layout.InputBytes)"))
if ($ExpectedPcmSHA256) { [IO.File]::AppendAllText($spec, "ExpectedPcmSHA256=$ExpectedPcmSHA256`n") }
if ($Serve) { [IO.File]::AppendAllText($spec, "Serve=True`n") }
if ($Speech) { [IO.File]::AppendAllText($spec, "Speech=True`n") }
$ready = if ($Serve) { '(?m)^(Listening|Passed)=' } else { '(?m)^Passed=' }
if ($AttributeBuffers) { [IO.File]::AppendAllText($spec, "AttributeBuffers=True`n") }
if ($ResidentPayloads) {
    if ($AttributeBuffers -or -not $layout.ResidentPayloads) { throw 'Resident payloads require the admitted adapter and no buffer probe.' }
    [IO.File]::AppendAllText($spec, "ResidentPayloads=True`n")
}
if ($null -ne $WeightAssembly) {
    if (-not $ResidentPayloads) { throw 'WeightAssembly requires ResidentPayloads.' }
    if ([long]$layout.WeightBytes -lt 1 -or [long]$WeightAssembly.Bytes -ne [long]$layout.WeightBytes) { throw 'Weight assembly extent differs from the generator layout.' }
    if ((Get-FileHash -LiteralPath $WeightAssembly.LoaderPath).Hash -cne $WeightAssembly.LoaderSHA256) { throw 'Staged managed loader hash differs.' }
    if ((Get-Item -LiteralPath $WeightAssembly.AssemblyPath).Length -ne $WeightAssembly.AssemblyBytes) { throw 'Weight assembly length differs.' }
    [IO.File]::AppendAllLines($spec, [string[]]@('WeightAssembly=True', "WeightOffset=$($WeightAssembly.Offset)", "WeightBytes=$($WeightAssembly.Bytes)", "WeightAssemblyBytes=$($WeightAssembly.AssemblyBytes)", "WeightIdentityOffset=$($WeightAssembly.IdentityOffset)", "WeightIdentity=$($WeightAssembly.Identity)"))
}
if ($RequestLifetime) {
    if (-not $ResidentPayloads -or $Runs -ne 31) { throw 'Request lifetime measurement requires resident payloads and 31 runs (one warmup and 30 requests).' }
    [IO.File]::AppendAllText($spec, "RequestLifetime=True`n")
}
$temp = "/data/local/tmp/kokoro-tail-$id"
$backup = "files/kokoro/generator-tail-backup-$id"
$target = 'files/kokoro/generator-tail'
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target files/kokoro/dsp && mkdir -p $temp")
$startupFiles = @('files/Start.ps1', 'files/PROFILE.PS1')
$startupState = @{}
foreach ($startupFile in $startupFiles) {
    $present = ((& $run @('shell', "if run-as $Package test -f $startupFile; then echo yes; fi")) -join '').Trim() -ceq 'yes'
    $originalHash = $null
    if ($present) {
        $originalHash = ((& $run @('shell', 'run-as', $Package, 'sha256sum', $startupFile)) -join '').Split(' ')[0]
        $null = & $run @('shell', "run-as $Package cp $startupFile $backup/$(Split-Path $startupFile -Leaf)")
    }
    $startupState[$startupFile] = [pscustomobject]@{ Present = $present; Hash = $originalHash }
}
$replaced = [Collections.Generic.List[string]]::new(); $changed = $false
try {
    $files = @(
        @($harness, "$target/KokoroGeneratorTailProbe.ps1"),
        @($binding, 'files/kokoro/Native.Binding.psm1'),
        @($aaudio, 'files/kokoro/Audio.AAudio.psm1'),
        @($library, 'files/kokoro/dsp/libkokoro_generator_tail_skel.so'),
        @($spec, "$target/spec.txt"))
    foreach ($n in 'activations.bin', 'tables.bin') { $files += , @((Join-Path $fixture $n), "$target/$n") }
    if ($null -ne $WeightAssembly) {
        $files += , @($WeightAssembly.AssemblyPath, "$target/Kokoro.Generator.Weights.dll")
        $files += , @($WeightAssembly.LoaderPath, "$target/Kokoro.MappedPayload.dll")
    } else { $files += , @((Join-Path $fixture 'weights.bin'), "$target/weights.bin") }
    foreach ($staged in $StageFiles.GetEnumerator()) { $files += , @($staged.Value, "files/$($staged.Key)") }
    foreach ($file in $files) {
        $name = Split-Path $file[1] -Leaf; $destination = $file[1]
        # Unchanged staged files (same SHA-256 already at the destination) are not pushed again: variant sweeps change
        # only the skel, not the 30-70 MB of weights.
        $localHash = if ($null -ne $WeightAssembly -and $name -ceq 'Kokoro.Generator.Weights.dll') { $WeightAssembly.AssemblySHA256 } else { (Get-FileHash $file[0]).Hash }
        if ($null -ne $WeightAssembly -and $name -ceq 'Kokoro.Generator.Weights.dll') {
            # Only activation hashes the weight file. Later launches trust the
            # private activation record and check length here, identity in CLR.
            $activation = ((& $run @('shell', "if run-as $Package test -f $destination.activation; then run-as $Package cat $destination.activation; fi")) -join '').Trim()
            if ($activation -ceq $WeightAssembly.AssemblySHA256) {
                $activeLength = ((& $run @('shell', 'run-as', $Package, 'stat', '-c', '%s', $destination)) -join '').Trim()
                if ([long]$activeLength -ne [long]$WeightAssembly.AssemblyBytes) { throw 'Activated weight assembly length differs.' }
                'WeightActivationReused=True PayloadHashPasses=0'
                continue
            }
        }
        $present = ((& $run @('shell', "run-as $Package sha256sum $destination 2>/dev/null || true")) -join '').Split(' ')[0]
        if ($present -eq $localHash) { continue }
        $null = & $run @('push', $file[0], "$temp/$name")
        $existing = (& $run @('shell', "if run-as $Package test -f $destination; then echo yes; fi")) -join ''
        if ($existing -eq 'yes') { $null = & $run @('shell', "run-as $Package cp $destination $backup/$name"); $replaced.Add($destination) }
        $null = & $run @('shell', "run-as $Package cp $temp/$name $destination.staged")
        $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', "$destination.staged") -join '').Split(' ')[0]
        if ($deviceHash -ne $localHash) { throw "Staged artifact hash mismatch for $name" }
        $deviceLength = ((& $run @('shell', 'run-as', $Package, 'stat', '-c', '%s', "$destination.staged")) -join '').Trim()
        if ([long]$deviceLength -ne (Get-Item -LiteralPath $file[0]).Length) { throw "Staged artifact length mismatch for $name" }
        $null = & $run @('shell', 'run-as', $Package, 'mv', "$destination.staged", $destination)
        if ($null -ne $WeightAssembly -and $name -ceq 'Kokoro.Generator.Weights.dll') {
            $null = & $run @('shell', "run-as $Package sh -c 'echo $localHash > $destination.activation.staged && mv $destination.activation.staged $destination.activation'")
        }
    }
    $null = & $run @('shell', "run-as $Package truncate -s 0 $target/receipt.txt")
    $startupUid = ((& $run @('shell', 'run-as', $Package, 'id', '-u')) -join '').Trim()
    $startupEpoch = ((& $run @('shell', 'date', '+%s')) -join '').Trim()
    if ($startupUid -notmatch '^\d+$' -or $startupEpoch -notmatch '^\d+$') { throw 'Project startup filter admission failed.' }
    $changed = $true
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/KokoroGeneratorTailProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroGeneratorTailProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n"
        if (-not $receipt.Trim() -and $watch.Elapsed.TotalSeconds -ge 30) { break }
        if ($receipt -match '(?m)^Started=' -and $receipt -notmatch $ready) {
            $alive = (& $run @('shell', "pidof $Package || true")) -join ''
            if (-not $alive.Trim()) { break }
        }
    }
    while ($receipt -notmatch $ready -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $receiptPath = Join-Path $emission "device-receipt-$Soc-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $hash = [regex]::Match($receipt, '(?m)^OutputSHA256=([0-9A-F]{64})')
    if ($hash.Success) {
        $outputPath = Join-Path $emission "device-output-$Soc-$id.bin"
        [IO.File]::WriteAllBytes($outputPath, [byte[]](& $Adb exec-out -Api -Device $serial "run-as $Package cat $target/tail-output.bin"))
        if ((Get-FileHash -LiteralPath $outputPath).Hash -cne $hash.Groups[1].Value) { throw 'Retrieved device output integrity mismatch.' }
        "OutputPath=$outputPath"
    }
    $wav = [regex]::Match($receipt, '(?m)^SpeechWav=speech\.wav SHA256=([0-9A-F]{64})')
    if ($wav.Success) {
        $wavPath = Join-Path $emission "speech-$Soc-$id.wav"
        [IO.File]::WriteAllBytes($wavPath, [byte[]](& $Adb exec-out -Api -Device $serial "run-as $Package cat $target/speech.wav"))
        if ((Get-FileHash -LiteralPath $wavPath).Hash -cne $wav.Groups[1].Value) { throw 'Retrieved speech WAV integrity mismatch.' }
        "SpeechPath=$wavPath"
    }
    $receipt
    "ReceiptPath=$receiptPath"
    if ($Serve -and $receipt -notmatch '(?m)^Listening=') { $receipt = $receipt -replace '(?m)^Passed=.*$', '' }
    if ($receipt -notmatch $ready) {
        $startupMarkers = [Collections.Generic.List[string]]::new()
        foreach ($line in ($receipt -split "`n" | Where-Object { $_ -match '^(Job|Started|ProbeStage)=' })) { $startupMarkers.Add($line) }
        $startupMarkers.Add("DiagnosticStarted=$($receipt -match '(?m)^Started=')")
        if ($startupUid -match '^\d+$') {
            # Read only the project UID, fixed Pwsh tag and this launch's time
            # window, including an early exit. Only source-defined labels leave memory.
            $startupLog = ((& $run @('logcat', '-d', '-T', "$startupEpoch.000", "--uid=$startupUid", '-s', 'Pwsh:I', 'libc:E', "'*:S'")) -join "`n")
            $fatal = [regex]::Match($startupLog, 'Fatal signal (6|11)\b')
            if ($fatal.Success) { $startupMarkers.Add("NativeFatalSignal=$($fatal.Groups[1].Value)") }
            foreach ($marker in 'GATE2A Admit returned', 'GATE2B begin', 'GATE2B exception',
                'GATE2C CreateDefault2', 'GATE2C CreateRunspace', 'GATE2C Open',
                'GATE2C DefaultRunspace set', 'GATE2D START_MISSING',
                'GATE2D START_INVOKE_BEGIN', 'GATE2D START_INVOKE_END') {
                if ($startupLog.Contains($marker, [StringComparison]::Ordinal)) { $startupMarkers.Add("HostStage=$marker") }
            }
            $startupError = @($startupLog -split "`n" | Where-Object { $_.Contains('GATE2B exception', [StringComparison]::Ordinal) }) -join "`n"
            foreach ($typeName in ([regex]::Matches($startupError, '\b(?:System|Microsoft)\.(?:[A-Za-z_][A-Za-z0-9_]*\.)*[A-Za-z_][A-Za-z0-9_]*Exception\b').Value | Sort-Object -Unique)) {
                $startupMarkers.Add("HostExceptionType=$typeName")
            }
            foreach ($errorCategory in 'Could not load file or assembly', 'Method not found',
                'Could not load type', 'Unable to load shared library', 'The type initializer') {
                if ($startupError.Contains($errorCategory, [StringComparison]::Ordinal)) { $startupMarkers.Add("HostErrorCategory=$errorCategory") }
            }
            foreach ($assemblyName in 'System.Management.Automation', 'System.Runtime', 'System.Private.CoreLib',
                'System.Console', 'System.Linq.Expressions', 'System.Reflection.Emit', 'Microsoft.PowerShell.Commands.Utility') {
                if ($startupError.Contains($assemblyName, [StringComparison]::Ordinal)) { $startupMarkers.Add("HostAssembly=$assemblyName") }
            }
        }
        [IO.File]::WriteAllLines($receiptPath, $startupMarkers)
        $startupMarkers.ToArray()
        throw 'Diagnostic did not complete; DSP execution remains unverified.'
    }
}
finally {
    if ($changed) {
        if (-not $Serve) { $null = & $run @('shell', 'am', 'force-stop', $Package) }
        foreach ($startupFile in $startupFiles) {
            if ($startupState[$startupFile].Present) {
                $null = & $run @('shell', "run-as $Package cp $backup/$(Split-Path $startupFile -Leaf) $startupFile")
                $restoredHash = ((& $run @('shell', 'run-as', $Package, 'sha256sum', $startupFile)) -join '').Split(' ')[0]
                if ($restoredHash -cne $startupState[$startupFile].Hash) { throw 'Startup restoration hash mismatch' }
            } else {
                # These two explicit project startup paths were absent before this diagnostic.
                $null = & $run @('shell', 'run-as', $Package, 'rm', '-f', $startupFile)
                $remaining = ((& $run @('shell', "if run-as $Package test -e $startupFile; then echo yes; fi")) -join '').Trim()
                if ($remaining -ceq 'yes') { throw 'Startup restoration did not preserve absence' }
            }
        }
        foreach ($d in $replaced) { $null = & $run @('shell', "run-as $Package cp $backup/$(Split-Path $d -Leaf) $d") }
        'StartupRestored=True'
    }
    $null = & $run @('shell', "rm -rf $temp")
}
