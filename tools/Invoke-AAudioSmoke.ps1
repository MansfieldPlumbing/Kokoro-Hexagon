#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Serial,
    [string]$Package = 'dev.mansfieldplumbing.androidsma.preview',
    [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-Hexagon\aaudio-smoke')
)
$ErrorActionPreference = 'Stop'
if ($Serial -notmatch '^[A-Za-z0-9._:-]{1,128}$') { throw 'Device selector is invalid.' }
if ($Package -notmatch '^[A-Za-z0-9_.]+$') { throw 'Package name is invalid.' }
$adb = (Get-Command adb -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$run = {
    param([string[]]$Arguments)
    $result = & $adb -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0])" }
    $result
}
$sourceRoot = Join-Path $PSScriptRoot '..\src\runspace'
$sources = @('AAudioSmoke.ps1', 'Audio.AAudio.psm1', 'Native.Binding.psm1')
foreach ($name in $sources) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot $name), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "$name does not parse." }
}
[IO.Directory]::CreateDirectory($BuildDirectory) | Out-Null
$id = [Guid]::NewGuid().ToString('N')
$temporary = "/data/local/tmp/kokoro-aaudio-$id"
$target = 'files/kokoro-fl/aaudio-smoke'
$backup = "files/kokoro-fl/aaudio-smoke-backup-$id"
$startHashes = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
$changed = $false
try {
    [void](& $run @('shell', "mkdir -p $temporary && run-as $Package mkdir -p $target $backup && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1"))
    foreach ($name in $sources) {
        $source = Join-Path $sourceRoot $name
        [void](& $run @('push', $source, "$temporary/$name"))
        [void](& $run @('shell', "run-as $Package cp $temporary/$name $target/$name"))
        $deviceHash = ((& $run @('shell', 'run-as', $Package, 'sha256sum', "$target/$name")) -join '').Split(' ')[0]
        if ($deviceHash -cne (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw "Staged source hash mismatch for $name."
        }
    }
    [void](& $run @('shell', "run-as $Package truncate -s 0 $target/receipt.txt"))
    $changed = $true
    [void](& $run @('shell', "am force-stop $Package && run-as $Package cp $target/AAudioSmoke.ps1 files/Start.ps1 && run-as $Package cp $target/AAudioSmoke.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1"))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $receipt = ''
    do {
        Start-Sleep -Milliseconds 250
        $receipt = (& $run @('shell', 'run-as', $Package, 'cat', "$target/receipt.txt")) -join "`n"
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 15)
    $receiptPath = Join-Path $BuildDirectory "aaudio-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    if ($receipt -notmatch '(?m)^Passed=True') { throw "AAudio smoke failed; receipt: $receiptPath" }
    $receipt
}
finally {
    if ($changed) {
        [void](& $run @('shell', "am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1"))
        $restored = @(& $run @('shell', 'run-as', $Package, 'sha256sum', 'files/Start.ps1', 'files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup scripts were not restored byte-for-byte.' }
    }
    [void](& $run @('shell', "rm -rf $temporary"))
}
