#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Serial = $env:KOKORO_QNN_SERIAL,
    [string] $EmissionDirectory = (Join-Path $PSScriptRoot '..\build\hexagon-emission\emitted\KokoroAlbertSoftmax3'),
    [string] $FixtureDirectory = (Join-Path $PSScriptRoot '..\build\albert-softmax3-fixture-001'),
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)
$ErrorActionPreference='Stop'
if($Package -cnotmatch '^[a-zA-Z0-9_.]+$'){throw 'Invalid diagnostic package.'}
$adb=(Get-Command adb -ErrorAction Stop).Source
if(-not $Serial){$devices=@(& $adb devices|Select-Object -Skip 1|Where-Object{$_ -match '\sdevice$'});if($devices.Count -ne 1){throw 'Provide KOKORO_QNN_SERIAL unless exactly one device is attached.'};$Serial=($devices[0]-split '\s+')[0]}
$run={param([string[]]$Arguments)$result=& $adb -s $Serial @Arguments 2>&1;if($LASTEXITCODE){throw "Device operation failed: $($Arguments[0])"};$result}
$harness=Join-Path $PSScriptRoot '..\src\runspace\KokoroAlbertSoftmax3Probe.ps1'
$library=Join-Path $EmissionDirectory 'libkokoro_albert_softmax3_skel.so';$manifest=Join-Path $FixtureDirectory 'fixture.json'
if((Get-FileHash $library).Hash -ne 'F8C015FEB5F918931766FF04674160CBBDDFD13459D86CAB19D7FFB02E710067' -or
   (Get-FileHash $manifest).Hash -ne 'DC9538FEF6AE232301135DDB74F8771FB51156791491CD7B781BB39263B21F57'){throw 'Emission or fixture identity differs.'}
$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $harness),[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Device harness does not parse.'}
$id=[Guid]::NewGuid().ToString('N');$temp="/data/local/tmp/kokoro-albert-softmax3-$id";$backup="files/kokoro-fl/albert-softmax3-backup-$id";$target='files/kokoro-fl/albert-softmax3-emitted'
$startHashes=@(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
$null=& $run @('shell',"run-as $Package mkdir -p $backup $target files/kokoro-fl/qnn && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $temp")
$changed=$false
try{
    $files=@(
        @($harness,'KokoroAlbertSoftmax3Probe.ps1',"$target/KokoroAlbertSoftmax3Probe.ps1"),
        @((Join-Path $PSScriptRoot '..\src\runspace\Native.Binding.psm1'),'Native.Binding.psm1','files/kokoro-fl/Native.Binding.psm1'),
        @($library,'libkokoro_albert_softmax3_skel.so','files/kokoro-fl/qnn/libkokoro_albert_softmax3_skel.so'),
        @($manifest,'fixture.json',"$target/fixture.json"),
        @((Join-Path $FixtureDirectory 'input.f32'),'input.f32',"$target/input.f32"),
        @((Join-Path $FixtureDirectory 'expected.f32'),'expected.f32',"$target/expected.f32"))
    foreach($file in $files){$null=& $run @('push',$file[0],"$temp/$($file[1])");$null=& $run @('shell',"if run-as $Package test -f $($file[2]); then run-as $Package cp $($file[2]) $backup/$($file[1]); fi; run-as $Package cp $temp/$($file[1]) $($file[2])");$deviceHash=((& $run @('shell','run-as',$Package,'sha256sum',$file[2]))-join '').Split(' ')[0];if($deviceHash -ine (Get-FileHash $file[0]).Hash){throw 'Staged artifact hash mismatch.'}}
    $null=& $run @('shell',"if run-as $Package test -f $target/receipt.txt; then run-as $Package cp $target/receipt.txt $backup/receipt.txt; fi; run-as $Package truncate -s 0 $target/receipt.txt")
    $changed=$true;$null=& $run @('shell',"am force-stop $Package && run-as $Package cp $target/KokoroAlbertSoftmax3Probe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroAlbertSoftmax3Probe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch=[Diagnostics.Stopwatch]::StartNew();$receipt='';do{Start-Sleep -Seconds 2;$receipt=(& $run @('shell','run-as',$Package,'cat',"$target/receipt.txt"))-join "`n"}while($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 90)
    $receiptPath=Join-Path $EmissionDirectory "device-receipt-$id.txt";[IO.File]::WriteAllText($receiptPath,$receipt)
    if($receipt -notmatch '(?m)^Passed=True'){throw "Device test failed or timed out; receipt: $receiptPath"};$receipt
}
finally{
    if($changed){$null=& $run @('shell',"am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1");$restored=@(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'));if(($restored-join "`n") -cne ($startHashes-join "`n")){throw 'Startup restoration hash mismatch.'};'StartupRestored=True'}
}
