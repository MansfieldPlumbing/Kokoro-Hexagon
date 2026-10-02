#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Serial = $env:KOKORO_QNN_SERIAL,
    [string] $EmissionDirectory = (Join-Path $PSScriptRoot '../build/albert-embedding-projection-vector-emission/KokoroLinearTile'),
    [string] $FixtureDirectory = (Join-Path $PSScriptRoot '../build/albert-embedding-projection-vector-fixture-001'),
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)

$ErrorActionPreference = 'Stop'
if ($Package -cnotmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid diagnostic package.' }
$adb = (Get-Command adb -ErrorAction Stop).Source
if (-not $Serial) {
    $devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\sdevice$' })
    if ($devices.Count -ne 1) { throw 'Provide KOKORO_QNN_SERIAL unless exactly one device is attached.' }
    $Serial = ($devices[0] -split '\s+')[0]
}
$run = { param([string[]] $Arguments)
    $result = & $adb -s $Serial @Arguments 2>&1
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0])" }
    $result
}
$harness = Join-Path $PSScriptRoot '../src/runspace/KokoroAlbertProjectionProbe.ps1'
$library = Join-Path $EmissionDirectory 'libkokoro_linear_skel.so'
$manifest = Join-Path $FixtureDirectory 'fixture.json'
$pair = ((Get-FileHash -LiteralPath $library).Hash + ':' + (Get-FileHash -LiteralPath $manifest).Hash)
$allowedPairs = @(
    'B9B0A1F5B08829DD9959DA856AD7111AB77577D3D132580805445931BB8048CB:85FA0928B442CF31E355A280399D78FA2425785BC5DE1623D651BA6EB1B1AF2D',
    '08121EC5923CDC66307FAB5DA9775BCF18035A1DD6933336A9F8273107A82F08:CC9364E94295578AAE1B486BB5F386CA21B71209E9684971C02527B2D7C68F0F',
    '96C74EB467644D731059B5087ADA5826263C1654C79C8E31162681261E1835B0:B319307E6C3C2BD82C82FCE615B1EF730272327E647BE9C5C40173293775A4B9',
    '96C74EB467644D731059B5087ADA5826263C1654C79C8E31162681261E1835B0:963944345EE278CC0DEA091CF86F48292D7E01956BF950D9CFBBE513E010F4FB',
    '96C74EB467644D731059B5087ADA5826263C1654C79C8E31162681261E1835B0:F92A75AA14C45BF44C09C5A5C193301615771044B32E216611C82EE895FF2B2F',
    'B883B334F79B7EFDF6F1EDC704EF1D9CE1472C3CF0B239AA7EE9F83A90796AFB:88E7D447221EF872E4AE01C6DC557F235F196BDF214EB4D695A92EB208475A9D',
    '75533B7D72E460489B4689A39CB0646914108FECB2939C2A45F5537829F655BD:CC1AD2352E3AF552462F18C0E44688D084787BD67B8458ED7C83B135EEB09FAB'
)
if ($pair -cnotin $allowedPairs) {
    throw 'Emission or fixture identity differs.'
}
$errors = $null; $tokens = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $harness).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Device harness does not parse.' }
$id = [Guid]::NewGuid().ToString('N')
$temp = "/data/local/tmp/kokoro-albert-$id"
$backup = "files/kokoro-fl/albert-backup-$id"
$target = 'files/kokoro-fl/albert-projection-emitted'
$startHashes = @(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
$null = & $run @('shell',"run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$changed = $false
try {
    $files = @(
        @($harness, 'KokoroAlbertProjectionProbe.ps1', "$target/KokoroAlbertProjectionProbe.ps1"),
        @((Join-Path $PSScriptRoot '../src/runspace/Native.Binding.psm1'), 'Native.Binding.psm1', 'files/kokoro-fl/Native.Binding.psm1'),
        @($library, 'libkokoro_linear_skel.so', 'files/kokoro-fl/qnn/libkokoro_linear_skel.so'),
        @($manifest, 'fixture.json', "$target/fixture.json"),
        @((Join-Path $FixtureDirectory 'input.f32'), 'input.f32', "$target/input.f32"),
        @((Join-Path $FixtureDirectory 'weights-bias.f32'), 'weights-bias.f32', "$target/weights-bias.f32"),
        @((Join-Path $FixtureDirectory 'expected.f32'), 'expected.f32', "$target/expected.f32")
    )
    foreach ($file in $files) {
        $null = & $run @('push',$file[0],"$temp/$($file[1])")
        $destination = $file[2]
        $null = & $run @('shell',"if run-as $Package test -f $destination; then run-as $Package cp $destination $backup/$($file[1]); fi; run-as $Package cp $temp/$($file[1]) $destination")
        $deviceHash = ((& $run @('shell','run-as',$Package,'sha256sum',$destination)) -join '').Split(' ')[0]
        if ($deviceHash -ine (Get-FileHash -LiteralPath $file[0]).Hash) { throw 'Staged artifact hash mismatch.' }
    }
    $null = & $run @('shell',"if run-as $Package test -f $target/receipt.txt; then run-as $Package cp $target/receipt.txt $backup/receipt.txt; fi; run-as $Package truncate -s 0 $target/receipt.txt")
    $changed = $true
    $null = & $run @('shell',"am force-stop $Package && run-as $Package cp $target/KokoroAlbertProjectionProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroAlbertProjectionProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch = [Diagnostics.Stopwatch]::StartNew(); $receipt = ''
    do {
        Start-Sleep -Seconds 2
        $receipt = (& $run @('shell','run-as',$Package,'cat',"$target/receipt.txt")) -join "`n"
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 90)
    $receiptPath = Join-Path $EmissionDirectory "device-receipt-$id.txt"
    [IO.File]::WriteAllText($receiptPath, $receipt)
    if ($receipt -notmatch '(?m)^Passed=True') { throw "Device test failed or timed out; receipt: $receiptPath" }
    $receipt
}
finally {
    if ($changed) {
        $null = & $run @('shell',"am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $restored = @(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
        if (($restored -join "`n") -cne ($startHashes -join "`n")) { throw 'Startup restoration hash mismatch.' }
        'StartupRestored=True'
    }
}
