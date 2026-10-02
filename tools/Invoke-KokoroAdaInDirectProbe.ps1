#requires -Version 7.4
# Reversible diagnostic deployment; numerical comparison stays on the PC.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [string]$Serial,
    [ValidatePattern('^[A-Za-z0-9_.]+$')][string]$Package='dev.mansfieldplumbing.androidsma.preview',
    [switch]$ResBlock,
    [ValidateRange(1,16)][int]$RepeatCount=1)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$adb=(Get-Command adb -ErrorAction Stop).Source
if(-not $Serial){
    $devices=@(& $adb devices | Where-Object {$_ -match '\tdevice$'})
    if($devices.Count -ne 1){throw 'Select one connected diagnostic device explicitly.'}
    $Serial=$devices[0].Split("`t")[0]
}
$run={param([string[]]$Arguments)
    $result=& $adb -s $Serial @Arguments 2>&1
    if($LASTEXITCODE){throw "Device operation failed: $($Arguments[0])"}
    $result
}
$fixture=Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw | ConvertFrom-Json
$role=if($ResBlock){'direct_adain_resblock_diagnostic'}else{'direct_adain_diagnostic'}
$expectedCases=if($ResBlock){2}else{13}
if($fixture.Schema -ne 1 -or $fixture.Role -cne $role -or $fixture.Cases.Count -ne $expectedCases){throw 'Unexpected fixture contract'}
$library=Join-Path $ArtifactDirectory $(if($ResBlock){'libkokoro_adain_resblock_skel.so'}else{'libkokoro_adain_skel.so'})
if(-not [IO.File]::Exists([IO.Path]::GetFullPath($library))){throw 'Emitted library is missing'}
$id=[Guid]::NewGuid().ToString('N')
$resultDir=Join-Path $repo "build/adain-device-$id"
[void][IO.Directory]::CreateDirectory($resultDir)
$target="files/kokoro-fl/adain-direct-$id"
$backup="files/kokoro-fl/adain-backup-$id"
$transfer="/data/local/tmp/kokoro-adain-$id"
$harnessSource=[IO.File]::ReadAllText((Join-Path $repo 'src/runspace/KokoroAdaInDirectProbe.ps1'))
$harnessSource=$harnessSource.Replace("'adain-direct'","'adain-direct-$id'")
if($ResBlock){$harnessSource=$harnessSource.Replace('$blockMode=$false','$blockMode=$true')}
$harnessSource=$harnessSource.Replace('$repeatCount=1',('$repeatCount='+$RepeatCount))
$harness=Join-Path $resultDir 'KokoroAdaInDirectProbe.ps1'
[IO.File]::WriteAllText($harness,$harnessSource)
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($harness,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Staged diagnostic harness has an AST error'}
$files=[Collections.Generic.List[object]]::new()
$files.Add(@($harness,'KokoroAdaInDirectProbe.ps1'))
$files.Add(@($library,[IO.Path]::GetFileName($library)))
$files.Add(@((Join-Path $repo 'src/runspace/Native.Binding.psm1'),'Native.Binding.psm1'))
foreach($f in $fixture.Files){
    if($f.Name -cnotmatch '^[a-z-]+\.(input|control|reference)\.bin$'){throw 'Invalid fixture file name'}
    $path=Join-Path $FixtureDirectory $f.Name
    if((Get-Item -LiteralPath $path).Length -ne $f.Bytes -or (Get-FileHash -LiteralPath $path).Hash -cne $f.SHA256){throw 'Fixture integrity mismatch'}
    if($f.Name -notlike '*.reference.bin'){$files.Add(@($path,$f.Name))}
}
$before=@(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
$null=& $run @('shell',"run-as $Package mkdir -p $target $backup && run-as $Package cp files/Start.ps1 $backup/Start.ps1 && run-as $Package cp files/PROFILE.PS1 $backup/PROFILE.PS1 && mkdir -p $transfer")
$changed=$false;$restored=$false
try {
    foreach($file in $files){
        $null=& $run @('push',$file[0],"$transfer/$($file[1])")
        $null=& $run @('shell','run-as',$Package,'cp',"$transfer/$($file[1])","$target/$($file[1])")
        $hash=((& $run @('shell','run-as',$Package,'sha256sum',"$target/$($file[1])"))-join '').Split(' ')[0]
        if($hash -ine (Get-FileHash -LiteralPath $file[0]).Hash){throw 'Staged artifact integrity mismatch'}
    }
    $changed=$true
    $null=& $run @('shell',"am force-stop $Package && run-as $Package cp $target/KokoroAdaInDirectProbe.ps1 files/Start.ps1 && run-as $Package cp $target/KokoroAdaInDirectProbe.ps1 files/PROFILE.PS1 && monkey -p $Package -c android.intent.category.LAUNCHER 1")
    $watch=[Diagnostics.Stopwatch]::StartNew();$receipt=''
    do {
        Start-Sleep -Milliseconds 500
        $raw=& $adb -s $Serial shell run-as $Package cat "$target/receipt.txt" 2>$null
        if($LASTEXITCODE -eq 0){$receipt=$raw -join "`n"}
    } while($receipt -notmatch '(?m)^Passed=' -and $watch.Elapsed.TotalSeconds -lt 50)
    [IO.File]::WriteAllText((Join-Path $resultDir 'device-receipt.txt'),$receipt)
    if($receipt -notmatch '(?m)^Passed=True'){throw "Device diagnostic did not pass; inspect $resultDir/device-receipt.txt"}
    $comparisons=[Collections.Generic.List[object]]::new()
    foreach($case in $fixture.Cases){
        if($case.ExpectedRc -ne 0){continue}
        $outputPath=Join-Path $resultDir $case.Output
        $start=[Diagnostics.ProcessStartInfo]::new($adb)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in @('-s',$Serial,'exec-out','run-as',$Package,'cat',"$target/$($case.Output)")){[void]$start.ArgumentList.Add($arg)}
        $process=[Diagnostics.Process]::Start($start)
        $file=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew)
        try {$process.StandardOutput.BaseStream.CopyTo($file);$process.WaitForExit();if($process.ExitCode -ne 0){throw 'Device output retrieval failed'}}
        finally {$file.Dispose();$process.Dispose()}
        [byte[]]$actualBytes=[IO.File]::ReadAllBytes($outputPath)
        [byte[]]$referenceBytes=[IO.File]::ReadAllBytes((Join-Path $FixtureDirectory ($case.Name+'.reference.bin')))
        if($actualBytes.Length -ne 32768 -or $referenceBytes.Length -ne 32768){throw 'Device tensor length mismatch'}
        $actual=[float[]]::new(8192);$reference=[float[]]::new(8192)
        [Buffer]::BlockCopy($actualBytes,0,$actual,0,32768);[Buffer]::BlockCopy($referenceBytes,0,$reference,0,32768)
        $max=0.0;$squares=0.0;$energy=0.0
        for($i=0;$i -lt 8192;$i++){
            if(-not [float]::IsFinite($actual[$i])){throw 'DSP output is non-finite'}
            $error=[double]$actual[$i]-$reference[$i];$max=[Math]::Max($max,[Math]::Abs($error))
            $squares+=$error*$error;$energy+=[double]$reference[$i]*$reference[$i]
        }
        $pass=$max -le 0.001
        $comparisons.Add([ordered]@{Case=$case.Name;Passed=$pass;MaxAbsError=$max;
            SnrDb=$(if($squares -eq 0){$null}else{10*[Math]::Log10($energy/$squares)});
            OutputSHA256=(Get-FileHash -LiteralPath $outputPath).Hash})
    }
    $summary=[ordered]@{Schema=1;LibrarySHA256=(Get-FileHash -LiteralPath $library).Hash;
        Model=((& $run @('shell','getprop','ro.product.model'))-join '').Trim();
        SoC=((& $run @('shell','getprop','ro.soc.model'))-join '').Trim();
        Scope=$(if($ResBlock){'direct_dsp_complete_adain_resblock'}else{'direct_dsp_full_time_adain_operator'});Transport='libcdsprpc_diagnostic';
        CheckpointSHA256=$fixture.CheckpointSHA256;Comparisons=$comparisons.ToArray();
        Passed=(@($comparisons|Where-Object {-not $_.Passed}).Count -eq 0)}
    [IO.File]::WriteAllText((Join-Path $resultDir 'comparison.json'),($summary|ConvertTo-Json -Depth 6))
    if(-not $summary.Passed){throw "Device numerical gate failed; inspect $resultDir/comparison.json"}
} finally {
    if($changed){
        $null=& $run @('shell',"am force-stop $Package && run-as $Package cp $backup/Start.ps1 files/Start.ps1 && run-as $Package cp $backup/PROFILE.PS1 files/PROFILE.PS1")
        $after=@(& $run @('shell','run-as',$Package,'sha256sum','files/Start.ps1','files/PROFILE.PS1'))
        if(($after -join "`n") -cne ($before -join "`n")){throw 'Startup restoration failed integrity check'}
        $restored=$true
    }
    [IO.File]::WriteAllText((Join-Path $resultDir 'restoration.json'),([ordered]@{StartupRestored=$restored}|ConvertTo-Json))
}
[pscustomobject]@{Passed=$true;ResultDirectory=$resultDir;StartupRestored=$restored;NumericalCases=$comparisons.Count}
