#requires -Version 7.4
# Windows diagnostic runner; vendor RPC is not product transport.
[CmdletBinding()]
param(
    [ValidateSet('arm64-v8a')][string]$Abi='arm64-v8a',
    [ValidateRange(26,100)][int]$ApiLevel,
    [string]$Serial,
    [switch]$ValidateDeviceSelection,
    [ValidateSet('Attention','Output','Connected')][string]$Stage='Attention',
    [string]$EmissionDirectory,[string]$FixtureDirectory,
    [ValidatePattern('^[a-zA-Z0-9_.]+$')][string]$Package='dev.mansfieldplumbing.kokoro',
    [ValidateRange(30,300)][int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
# Selection is a capability filter, not device identity. ADB transport handles
# remain transient variables and are never emitted or written to receipts.
function Select-KokoroDiagnosticTarget {
    param([AllowEmptyCollection()][object[]]$Candidates,[string]$TargetAbi,[int]$TargetApi)
    $matches=@($Candidates|Where-Object { $_.Abi -ceq $TargetAbi -and $_.Api -eq $TargetApi })
    if ($matches.Count -ne 1 -or -not $matches[0].Transport) { throw 'Expected exactly one ready device matching the authorized ABI/API.' }
    $matches[0]
}
if ($ValidateDeviceSelection) {
    $valid=[pscustomobject]@{Abi='arm64-v8a';Api=36;Transport='candidate_a'}
    $wrongAbi=[pscustomobject]@{Abi='x86_64';Api=36;Transport='candidate_b'}
    $wrongApi=[pscustomobject]@{Abi='arm64-v8a';Api=34;Transport='candidate_c'}
    if ((Select-KokoroDiagnosticTarget @($valid) 'arm64-v8a' 36).Transport -cne 'candidate_a' -or
        (Select-KokoroDiagnosticTarget @($wrongAbi,$valid,$wrongApi) 'arm64-v8a' 36).Transport -cne 'candidate_a') { throw 'Unique capability selection failed.' }
    $rejections=0
    foreach ($case in @(@{Items=@()},@{Items=@($wrongAbi)},@{Items=@($wrongApi)},
        @{Items=@($valid,$valid)},@{Items=@([pscustomobject]@{Abi='arm64-v8a';Api=36;Transport=''})})) {
        try { $null=Select-KokoroDiagnosticTarget $case.Items 'arm64-v8a' 36 } catch { $rejections++ }
    }
    if ($rejections -ne 5) { throw 'Unsafe device selection admitted.' }
    [pscustomobject]@{Passed=$true;UniqueSelectionsVerified=2;InvalidSelectionsRejected=$rejections;DeviceAccessed=$false}
    return
}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$adb=(Get-Command adb -ErrorAction Stop).Source
if ($Stage -eq 'Connected') {
    if (-not $EmissionDirectory) { $EmissionDirectory=Join-Path $repo 'build/spikes/connected-attention-20261004/emitted-v2/KokoroAlbertConnectedAttention3' }
    if (-not $FixtureDirectory) { $FixtureDirectory=Join-Path $repo 'build/spikes/connected-attention-20261004/fixture' }
    $libraryName='libkokoro_albert_connected_attention3_skel.so'
    $libraryHash='0502E64043BFEB7CD979F7626D30908B438BAA5A26F12EBFE7A2BA298781CF11'
    $manifestHashes=@('35C4AB66C4C8CB32194D117F2A56006B7D6E35F8B1AD3AA8A749AA9577643D7F')
} elseif ($Stage -eq 'Output') {
    if (-not $EmissionDirectory) { $EmissionDirectory=Join-Path $repo 'build/spikes/connected-attention-20261003/KokoroAlbertAttentionOutput3' }
    if (-not $FixtureDirectory) { $FixtureDirectory=Join-Path $repo 'build/albert-attention-output3-fixture-20261002' }
    $libraryName='libkokoro_albert_attention_output3_skel.so'
    $libraryHash='C7F1164999CB8BC8929EBFCB6FF2DFB046DB8272C7FE8220C2EE91AF3E441B6C'
    $manifestHashes=@('B199DD7515407557BA9ABE302BE25A217D66BE32DCE975A7A71B68A5BA759146','D35B4CC581E9A995C268FDBFBC99EB186ED93CE69A2A0AE5D834649A47D5A5EA')
} else {
    if (-not $EmissionDirectory) { $EmissionDirectory=Join-Path $repo 'build/hexagon-emission/emitted/KokoroAlbertAttention3' }
    if (-not $FixtureDirectory) { $FixtureDirectory=Join-Path $repo 'build/albert-attention3-fixture-001' }
    $libraryName='libkokoro_albert_attention3_skel.so'
    $libraryHash='36E9FF41F6F622B27B8725DDB7E1ADA687C6D315F7C8034606BC38DF3904CF9F'
    $manifestHashes=@('08E767B7482C755CA70C59F53A9F69040DFE626AE290206FE3C4566978DEA76E')
}
$library=Join-Path $EmissionDirectory $libraryName; $manifest=Join-Path $FixtureDirectory 'fixture.json'
if ((Get-FileHash -LiteralPath $library).Hash -cne $libraryHash -or (Get-FileHash -LiteralPath $manifest).Hash -cnotin $manifestHashes) { throw 'Emission or fixture identity differs.' }
$fixture=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
$files=[Collections.Generic.List[object]]::new()
$files.Add(@((Join-Path $repo 'src/runspace/KokoroAlbertAttention3Probe.ps1'),'KokoroAlbertAttention3Probe.ps1'))
$files.Add(@((Join-Path $repo 'src/runspace/Native.Binding.psm1'),'Native.Binding.psm1'))
if ((Get-FileHash -LiteralPath $files[1][0]).Hash -cne '7A42BF2FE487C303116E315CA594736B2D3FDA24FE2741618736427AB062E89F') { throw 'Native binding source pin differs.' }
$files.Add(@($library,$libraryName)); $files.Add(@($manifest,'fixture.json'))
$payloads=if ($Stage -in @('Output','Connected')) { @('Input','Weights','Expected') } else { @('Input','Expected') }
foreach ($property in $payloads) {
    $record=$fixture.$property
    if ($record.Name -cnotmatch '^[a-z0-9-]+\.f32$') { throw 'Invalid fixture payload name.' }
    $path=Join-Path $FixtureDirectory $record.Name
    if ((Get-Item -LiteralPath $path).Length -ne $record.Bytes -or (Get-FileHash -LiteralPath $path).Hash -cne $record.SHA256) { throw 'Fixture payload identity differs.' }
    $files.Add(@($path,$record.Name))
}
foreach ($file in $files) {
    if ([IO.Path]::GetExtension($file[0]) -in @('.ps1','.psm1')) {
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file[0],[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Staged PowerShell source does not parse.' }
    }
}
if ($ApiLevel) {
    if ($PSBoundParameters.ContainsKey('Serial')) { throw 'Select by ABI/API or explicit transport, not both.' }
    $devices=@(& $adb devices 2>$null|Where-Object { $_ -match '^\S+\s+device$' }|ForEach-Object { ($_ -split '\s+')[0] })
    $candidates=@(foreach ($device in $devices) {
        $candidateAbi=(& $adb -s $device shell getprop ro.product.cpu.abi 2>$null|Out-String).Trim()
        $candidateApi=(& $adb -s $device shell getprop ro.build.version.sdk 2>$null|Out-String).Trim()
        if ($candidateApi -cmatch '^\d{2,3}$') { [pscustomobject]@{Transport=$device;Abi=$candidateAbi;Api=[int]$candidateApi} }
    })
    $selected=Select-KokoroDiagnosticTarget $candidates $Abi $ApiLevel
    $Serial=$selected.Transport
} elseif (-not $Serial) { throw 'Select the authorized ABI/API target explicitly.' }
$run={
    param([string[]]$Arguments)
    $result=@(& $adb -s $Serial @Arguments 2>&1)
    if ($LASTEXITCODE) { throw "Device operation failed: $($Arguments[0])" }
    $result
}
$null=& $run @('shell','run-as',$Package,'pwd')
# Pinned Pwsh setup 4afa9ae...:5836 admits android.app.NativeActivity.
# A different installed activity does not establish that profile ingress exists.
$component=(@(& $run @('shell','cmd','package','resolve-activity','--brief',$Package))|Select-Object -Last 1).ToString().Trim()
if ($component -cne ($Package+'/android.app.NativeActivity')) { throw 'Installed diagnostic activity does not match the admitted NativeActivity ingress; no staging performed.' }
# Inspect only the case-insensitive startup filename, not unrelated app content.
$profiles=@(& $run @('shell',"run-as $Package find files -maxdepth 1 -type f -iname profile.ps1")|Where-Object { $_.ToString().Trim() })
if ($profiles.Count -gt 1) { throw 'Ambiguous diagnostic startup profile.' }
$hadProfile=$profiles.Count -eq 1
$profile=if ($hadProfile) { $profiles[0].ToString().Trim() } else { 'files/Profile.ps1' }
if ($profile -cnotmatch '^files/[Pp][Rr][Oo][Ff][Ii][Ll][Ee]\.[Pp][Ss]1$') { throw 'Unexpected startup path.' }
$profileHash=if ($hadProfile) { ((& $run @('shell','run-as',$Package,'sha256sum',$profile))-join '').Split(' ')[0] } else { $null }
$id=[Guid]::NewGuid().ToString('N'); $relative="kokoro-fl/albert-session-$id"
$target="files/$relative"; $temp="/data/local/tmp/kokoro-albert-$id"
$local=Join-Path $EmissionDirectory "device-session-$id"; [void][IO.Directory]::CreateDirectory($local)
$launcher=Join-Path $local 'Profile.ps1'
# Generated launcher contains only fixed owned paths and an admitted stage enum.
$admittedManifestHash=(Get-FileHash -LiteralPath $manifest).Hash
$launcherText="& (Join-Path `$PSScriptRoot '$relative/KokoroAlbertAttention3Probe.ps1') -Stage '$Stage' -HostVerifiedManifestSHA256 '$admittedManifestHash' -DiagnosticDirectory (Join-Path `$PSScriptRoot '$relative')`n"
[IO.File]::WriteAllText($launcher,$launcherText,[Text.UTF8Encoding]::new($false))
$tokens=$null; $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Generated launcher failed AST admission.' }
$files.Add(@($launcher,'Profile.ps1'))
$artifactRecords=@(foreach ($file in $files) {
    [ordered]@{Name=$file[1];Bytes=(Get-Item -LiteralPath $file[0]).Length;SHA256=(Get-FileHash -LiteralPath $file[0]).Hash}
})
$sourceRecord=[ordered]@{Schema=1;Stage=$Stage;Package=$Package;TimeoutSeconds=$TimeoutSeconds;Artifacts=$artifactRecords}
[IO.File]::WriteAllText((Join-Path $local 'staged-inputs.json'),($sourceRecord|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$startupChanged=$false; $sessionCreated=$false
try {
    $null=& $run @('shell',"run-as $Package mkdir -p $target && mkdir -p $temp"); $sessionCreated=$true
    if ($hadProfile) {
        $null=& $run @('shell','run-as',$Package,'cp',$profile,"$target/original-profile.ps1")
        $backupHash=((& $run @('shell','run-as',$Package,'sha256sum',"$target/original-profile.ps1"))-join '').Split(' ')[0]
        if ($backupHash -cne $profileHash) { throw 'Startup backup verification failed.' }
    }
    foreach ($file in $files) {
        $null=& $run @('push',$file[0],"$temp/$($file[1])")
        $null=& $run @('shell','run-as',$Package,'cp',"$temp/$($file[1])","$target/$($file[1])")
        $deviceHash=((& $run @('shell','run-as',$Package,'sha256sum',"$target/$($file[1])"))-join '').Split(' ')[0]
        if ($deviceHash -ine (Get-FileHash -LiteralPath $file[0]).Hash) { throw 'Staged artifact hash mismatch.' }
    }
    # Do not overwrite startup work created or changed during staging.
    $latestProfiles=@(& $run @('shell',"run-as $Package find files -maxdepth 1 -type f -iname profile.ps1")|Where-Object { $_.ToString().Trim() })
    if ($hadProfile) {
        if ($latestProfiles.Count -ne 1 -or $latestProfiles[0].ToString().Trim() -cne $profile) { throw 'Startup changed during staging.' }
        $latestHash=((& $run @('shell','run-as',$Package,'sha256sum',$profile))-join '').Split(' ')[0]
        if ($latestHash -cne $profileHash) { throw 'Startup content changed during staging.' }
    } elseif ($latestProfiles.Count) { throw 'Startup appeared during staging.' }
    $null=& $run @('shell','am','force-stop',$Package); $startupChanged=$true
    $null=& $run @('shell','run-as',$Package,'cp',"$target/Profile.ps1",$profile)
    $null=& $run @('shell','monkey','-p',$Package,'-c','android.intent.category.LAUNCHER','1')
    $watch=[Diagnostics.Stopwatch]::StartNew(); $receipt=''
    do {
        Start-Sleep -Seconds 2
        $null=& $adb -s $Serial shell run-as $Package test -f "$target/receipt.txt" 2>$null
        if ($LASTEXITCODE -eq 0) { $receipt=(& $run @('shell','run-as',$Package,'cat',"$target/receipt.txt"))-join "`n" }
        $running=((& $adb -s $Serial shell pidof $Package 2>$null) -join '').Trim()
        if ($receipt) { [IO.File]::WriteAllText((Join-Path $local 'receipt.txt'),$receipt,[Text.UTF8Encoding]::new($false)) }
        if (-not $running -and $receipt -notmatch '(?m)^Passed=') { throw 'Diagnostic process exited before completing its receipt.' }
    } while ($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $receiptPath=Join-Path $local 'receipt.txt'; [IO.File]::WriteAllText($receiptPath,$receipt,[Text.UTF8Encoding]::new($false))
    if ($receipt -notmatch '(?m)^Passed=True') { throw "Device gate failed or timed out; local receipt: $receiptPath" }
    $receipt
} finally {
    $restored=-not $startupChanged
    if ($startupChanged) {
        $null=& $run @('shell','am','force-stop',$Package)
        if ($hadProfile) {
            $null=& $run @('shell','run-as',$Package,'cp',"$target/original-profile.ps1",$profile)
            $restoredHash=((& $run @('shell','run-as',$Package,'sha256sum',$profile))-join '').Split(' ')[0]
            $restored=$restoredHash -ceq $profileHash
        } else {
            $null=& $run @('shell','run-as',$Package,'rm',$profile)
            $null=& $adb -s $Serial shell run-as $Package test -e $profile 2>$null
            $restored=$LASTEXITCODE -eq 1
        }
    }
    if (-not $restored) { throw 'Startup restoration failed; session backup retained.' }
    if ($sessionCreated) {
        if ($target -cnotmatch '^files/kokoro-fl/albert-session-[a-f0-9]{32}$' -or $temp -cnotmatch '^/data/local/tmp/kokoro-albert-[a-f0-9]{32}$') { throw 'Cleanup path rejected.' }
        # Exact GUID-scoped paths created above, never an application root.
        $null=& $run @('shell','run-as',$Package,'rm','-r',$target)
        $null=& $run @('shell','rm','-r',$temp)
    }
    'StartupRestored=True'
}
