#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Serial=$env:KOKORO_QNN_SERIAL,
    [string]$BuildDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\hexagon-emission\conv-tile'),
    [string]$Package='dev.mansfieldplumbing.androidsma.preview'
)
$ErrorActionPreference='Stop'
if(-not $Serial -or $Package -notmatch '^[a-zA-Z0-9_.]+$'){throw 'Provide KOKORO_QNN_SERIAL and a valid package'}
$adb=(Get-Command adb -ErrorAction Stop).Source
$run={param([string[]]$Arguments)
    $result=& $adb -s $Serial @Arguments 2>&1
    if($LASTEXITCODE){throw "Device operation failed: $($Arguments[0])"}
    $result
}
$harness=Join-Path $PSScriptRoot '..\src\runspace\KokoroConvTileProbe.ps1'
$tokens=$null; $errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($harness,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Device harness does not parse'}
$library=Join-Path $BuildDirectory 'libkokoro_conv_skel.so'
if((Get-FileHash $library).Hash -ne 'C5953CE583A074CEFD96605FD65ACE31AEBC1E1B7917AA9ECCBE42EBE2372E59'){throw 'Library pin mismatch'}
$id=[Guid]::NewGuid().ToString('N'); $temp="/data/local/tmp/kokoro-conv-$id"
$backup="files/kokoro-fl/conv-backup-$id"; $target='files/kokoro-fl/conv-tile-emitted'
$startHashes=@(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
$null=& $run @('shell',"run-as $Package mkdir -p $backup $target && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$changed=$false
try {
    $files=@(@($harness,'KokoroConvTileProbe.ps1'),@($library,'libkokoro_conv_skel.so'))
    foreach($name in 'reference.json','input-0.f32','input-4096.f32','input-7616.f32'){
        $files+=,@((Join-Path $BuildDirectory "reference\$name"),$name)
    }
    foreach($file in $files){
        $name=$file[1]; $null=& $run @('push',$file[0],"$temp/$name")
        $destination=if($name.EndsWith('.so')){"files/kokoro-fl/qnn/$name"}else{"$target/$name"}
        # Preserve a previous staged test before replacing its artifacts.
        $null=& $run @('shell',"if run-as $Package test -f $destination; then run-as $Package cp $destination $backup/$name; fi; run-as $Package cp $temp/$name $destination")
        $deviceHash=(& $run @('shell','run-as',$Package,'sha256sum',$destination) -join '').Split(' ')[0]
        if($deviceHash -ne (Get-FileHash $file[0]).Hash){throw 'Staged artifact hash mismatch'}
    }
    $null=& $run @('shell',"if run-as $Package test -f $target/receipt.txt; then run-as $Package cp $target/receipt.txt $backup/receipt.txt; fi; run-as $Package truncate -s 0 $target/receipt.txt")
    $changed=$true
    $null=& $run @('shell',"am force-stop $Package && run-as $Package cp $target/KokoroConvTileProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroConvTileProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch=[Diagnostics.Stopwatch]::StartNew(); $receipt=''
    do {
        Start-Sleep -Seconds 2
        $receipt=(& $run @('shell','run-as',$Package,'cat',"$target/receipt.txt")) -join "`n"
    } while($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 90)
    $receiptPath=Join-Path $BuildDirectory "device-receipt-$id.txt"
    [IO.File]::WriteAllText($receiptPath,$receipt)
    $receipt
    if($receipt -notmatch '(?m)^Passed=True'){throw "Device test failed or timed out; receipt: $receiptPath"}
}
finally {
    if($changed){
        $null=& $run @('shell',"am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $restored=@(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
        if(($restored -join "`n") -cne ($startHashes -join "`n")){throw 'Startup restoration hash mismatch'}
        'StartupRestored=True'
    }
}
