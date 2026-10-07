#requires -Version 7.4
<#
.SYNOPSIS
Asks the pinned QNN 2.46 HTP runtime on an attached phone what it reports for the SoC (VTCM size,
SoC model, architecture). Diagnostic only; QNN is never part of the product.

.DESCRIPTION
Stages the harness, Native.Binding.psm1 and the QNN runtime from -RuntimeDirectory (each checked
against lib/manifest.json) into the host app's private storage, runs the harness as the startup
script, then restores the startup scripts and replaced files, removes files it added, and verifies
the restore by hash. The phone is selected by ro.soc.model; no serial is printed.
#>
param(
    [string] $RuntimeDirectory = (Join-Path $PSScriptRoot '..\build\qnn-runtime-2.46'),
    [ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
    [string] $Adb = 'C:\backup\Android\platform-tools\adb.exe',
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview',
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
foreach ($c in $Package.ToCharArray()) { if (-not ([char]::IsAsciiLetterOrDigit($c) -or $c -eq '_' -or $c -eq '.')) { throw 'Invalid Android package name' } }
$manifest = Get-Content (Join-Path $PSScriptRoot '..\lib\manifest.json') -Raw | ConvertFrom-Json
$runtime = foreach ($n in 'libQnnHtp.so', 'libQnnHtpV73Stub.so', 'libQnnHtpV73Skel.so') {
    $pin = $manifest.deviceRuntime.files | Where-Object path -eq $n
    $p = Join-Path $RuntimeDirectory $n
    if ((Get-FileHash $p).Hash -ne $pin.sha256 -or (Get-Item $p).Length -ne $pin.bytes) { throw "$n does not match lib/manifest.json" }
    , @($p, "files/kokoro-fl/qnn/$n")
}
$serials = @(& $Adb devices | ForEach-Object { $p = $_.Split("`t"); if ($p.Count -eq 2 -and $p[1] -eq 'device') { $p[0] } } |
    Where-Object { (& $Adb -s $_ shell getprop ro.soc.model).Trim() -eq $Soc })
if ($serials.Count -ne 1) { throw "Expected exactly one attached $Soc device, found $($serials.Count)." }
$serial = $serials[0]
$run = { param([string[]]$Arguments)
    $result = & $Adb -s $serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0]) $($Arguments[1])" }
    $result
}
$harness = Join-Path $PSScriptRoot '..\src\runspace\QnnPlatformInfoProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
foreach ($p in $harness, $binding) { $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); if ($e.Count) { throw "Does not parse: $p" } }

$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/kokoro-qnn-platform-$id"
$backup = "files/kokoro-fl/qnn-platform-backup-$id"
$target = 'files/kokoro-fl/qnn-platform'
$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$replaced = [Collections.Generic.List[string]]::new(); $added = [Collections.Generic.List[string]]::new()
$changed = $false
try {
    $files = @(@($harness, "$target/QnnPlatformInfoProbe.ps1"), @($binding, 'files/kokoro-fl/Native.Binding.psm1')) + $runtime
    foreach ($file in $files) {
        $name = Split-Path $file[1] -Leaf; $destination = $file[1]
        $null = & $run @('push', $file[0], "$temp/$name")
        $existing = (& $run @('shell', "if run-as $Package test -f $destination; then echo yes; fi")) -join ''
        if ($existing -eq 'yes') { $null = & $run @('shell', "run-as $Package cp $destination $backup/$name"); $replaced.Add($destination) } else { $added.Add($destination) }
        $null = & $run @('shell', "run-as $Package cp $temp/$name $destination")
        $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', $destination) -join '').Split(' ')[0]
        if ($deviceHash -ne (Get-FileHash $file[0]).Hash) { throw "Staged artifact hash mismatch for $name" }
    }
    $null = & $run @('shell', "run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/QnnPlatformInfoProbe.ps1 files/Start.ps1 && run-as $Package cp $target/QnnPlatformInfoProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $receiptLines = @(& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt"))
        $done = @($receiptLines | Where-Object { $_.StartsWith('Passed=') }).Count -gt 0
    } while (-not $done -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $receipt = $receiptLines -join "`n"
    $outDir = Join-Path $PSScriptRoot '..\build\qnn-platform-info'
    [void][IO.Directory]::CreateDirectory($outDir)
    $receiptPath = Join-Path $outDir "device-receipt-$Soc-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    $receipt
    "ReceiptPath=$receiptPath"
}
finally {
    if ($changed) {
        $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        foreach ($d in $replaced) { $null = & $run @('shell', "run-as $Package cp $backup/$(Split-Path $d -Leaf) $d") }
        $restored = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch' }
        'StartupRestored=True'
    }
    foreach ($d in $added) { $null = & $run @('shell', "run-as $Package rm -f $d") }
    if ($added.Count) { "RemovedAdded=$($added.Count)" }
    $null = & $run @('shell', "rm -rf $temp")
}
