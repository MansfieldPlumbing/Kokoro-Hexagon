#requires -Version 7.4
# Restore a diagnostic-only worker artifact from the S23 app to the Razr+ app.
# The binary is not a product dependency; its source is not in this checkout.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$package = 'dev.mansfieldplumbing.androidsma.preview'
$relative = 'files/kokoro-fl/qnn/libkokoro_queue_skel.so'
$serials = @(& adb devices | Where-Object { $_ -match '^\S+\s+device$' } |
    ForEach-Object { ($_ -split '\s+')[0] })
$s23 = @($serials | Where-Object { (& adb -s $_ shell getprop ro.product.model).Trim() -eq 'SM-S911U' })
$razr = @($serials | Where-Object { (& adb -s $_ shell getprop ro.product.model).Trim() -match 'razr plus 2024' })
if ($s23.Count -ne 1 -or $razr.Count -ne 1) { throw 'Expected one attached S23 and one Razr+.' }
$sourceHash = ((& adb -s $s23[0] shell run-as $package sha256sum $relative) -split '\s+')[0]
if ($LASTEXITCODE -ne 0 -or $sourceHash -notmatch '^[0-9a-f]{64}$') {
    throw 'Source diagnostic artifact was not readable.'
}
& adb -s $razr[0] shell run-as $package test -e $relative 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'Razr+ diagnostic artifact already exists; refusing to overwrite.' }

$outDir = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..', '..', 'build', 'diagnostics'))
[void][IO.Directory]::CreateDirectory($outDir)
$local = [IO.Path]::Combine($outDir, 'libkokoro_queue_skel.s23-recovered.so')
if (-not [IO.File]::Exists($local)) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command adb).Source
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('-s', $s23[0], 'exec-out', 'run-as', $package, 'cat', $relative)) {
        [void]$start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stream = [IO.FileStream]::new($local, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $process.StandardOutput.BaseStream.CopyTo($stream) }
        finally { $stream.Dispose() }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Diagnostic artifact extraction failed.' }
    } finally { $process.Dispose() }
}
if ((Get-FileHash -Algorithm SHA256 $local).Hash -ne $sourceHash) {
    throw 'Diagnostic artifact digest mismatch after extraction.'
}
$deviceTemp = '/data/local/tmp/kokoro-queue-diagnostic-' + [Guid]::NewGuid().ToString('N') + '.so'
& adb -s $razr[0] push $local $deviceTemp | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic artifact transfer failed.' }
& adb -s $razr[0] shell run-as $package cp $deviceTemp $relative | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic artifact placement failed.' }
$targetHash = ((& adb -s $razr[0] shell run-as $package sha256sum $relative) -split '\s+')[0]
if ($targetHash -cne $sourceHash) { throw 'Diagnostic artifact digest mismatch on Razr+.' }
[pscustomobject]@{
    Source = 'S23 diagnostic app archive'
    Destination = 'Razr+ diagnostic app only'
    ByteIdentical = $true
    ProductionArtifact = $false
}
