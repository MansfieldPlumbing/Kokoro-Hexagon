#requires -Version 7.4
<#
.SYNOPSIS
Runs the emitted VTCM query skel on an attached phone and returns its receipt.

.DESCRIPTION
Stages the emitted skel, Native.Binding.psm1 and the device harness into the host app's private
storage (hash-checked), runs the harness as the app's startup script, then restores the startup
scripts and any replaced file and verifies the restore by hash. The phone is selected by
ro.soc.model; no serial is printed.
#>
param(
    [Parameter(Mandatory)][string] $LibraryPath,
    [ValidateSet('SM8550', 'SM8635')][string] $Soc = 'SM8550',
    [string] $Adb = 'C:\backup\Android\platform-tools\adb.exe',
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview',
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 90
)
$ErrorActionPreference = 'Stop'
foreach ($c in $Package.ToCharArray()) { if (-not ([char]::IsAsciiLetterOrDigit($c) -or $c -eq '_' -or $c -eq '.')) { throw 'Invalid Android package name' } }
$serials = @(& $Adb devices | ForEach-Object { $p = $_.Split("`t"); if ($p.Count -eq 2 -and $p[1] -eq 'device') { $p[0] } } |
    Where-Object { (& $Adb -s $_ shell getprop ro.soc.model).Trim() -eq $Soc })
if ($serials.Count -ne 1) { throw "Expected exactly one attached $Soc device, found $($serials.Count)." }
$serial = $serials[0]
$run = { param([string[]]$Arguments)
    $result = & $Adb -s $serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0]) $($Arguments[1])" }
    $result
}
$harness = Join-Path $PSScriptRoot '..\src\runspace\KokoroVtcmQueryProbe.ps1'
$binding = Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'
foreach ($p in $harness, $binding) { $e = $null; $null = [Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$e); if ($e.Count) { throw "Does not parse: $p" } }

$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/kokoro-vtcm-query-$id"
$backup = "files/kokoro-fl/vtcm-query-backup-$id"
$target = 'files/kokoro-fl/vtcm-query'
$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$null = & $run @('shell', "run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$replaced = [Collections.Generic.List[string]]::new()
$changed = $false
try {
    $files = @(
        @($harness, "$target/KokoroVtcmQueryProbe.ps1"),
        @($binding, 'files/kokoro-fl/Native.Binding.psm1'),
        @($LibraryPath, 'files/kokoro-fl/qnn/libkokoro_vtcm_query_skel.so'))
    foreach ($file in $files) {
        $name = Split-Path $file[1] -Leaf; $destination = $file[1]
        $null = & $run @('push', $file[0], "$temp/$name")
        $existing = (& $run @('shell', "if run-as $Package test -f $destination; then echo yes; fi")) -join ''
        if ($existing -eq 'yes') { $null = & $run @('shell', "run-as $Package cp $destination $backup/$name"); $replaced.Add($destination) }
        $null = & $run @('shell', "run-as $Package cp $temp/$name $destination")
        $deviceHash = (& $run @('shell', 'run-as', $Package, 'sha256sum', $destination) -join '').Split(' ')[0]
        if ($deviceHash -ne (Get-FileHash $file[0]).Hash) { throw "Staged artifact hash mismatch for $name" }
    }
    $null = & $run @('shell', "run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true
    $null = & $run @('shell', "am force-stop $Package && run-as $Package cp $target/KokoroVtcmQueryProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroVtcmQueryProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $receiptLines = @(& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt"))
        $done = @($receiptLines | Where-Object { $_.StartsWith('Passed=') }).Count -gt 0
    } while (-not $done -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $receipt = $receiptLines -join "`n"
    $receiptPath = Join-Path (Split-Path $LibraryPath -Parent) "device-receipt-$Soc-$id.txt"
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
    $null = & $run @('shell', "rm -rf $temp")
}
