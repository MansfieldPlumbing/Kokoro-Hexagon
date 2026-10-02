#requires -Version 7.4
# Check the earliest stock consumer (Snake1D) on PC after device AdaIN output.
# This is a bounded diagnostic; Snake emission is not established by this gate.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResultDirectory,
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [string]$CheckpointPath='C:\models\Kokoro-82M\kokoro-v1_0.pth')
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=[IO.Path]::GetFullPath($ResultDirectory)
if(-not $out.StartsWith((Join-Path $repo 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
    throw 'Receipt directory must be inside repository build.'
}
$receiptPath=Join-Path $out 'consumer-comparison.json'
if([IO.File]::Exists($receiptPath)){throw 'Consumer receipt already exists.'}
$device=Get-Content -LiteralPath (Join-Path $out 'comparison.json') -Raw|ConvertFrom-Json
if(-not $device.Passed -or $device.Scope -cne 'direct_dsp_full_time_adain_operator'){throw 'Missing passing device AdaIN gate'}
$weights=& (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') -CheckpointPath $CheckpointPath -SkipFiniteScan
if($weights.CheckpointSha256 -cne $device.CheckpointSHA256){throw 'Consumer checkpoint identity differs'}
$alpha=$weights.Parameters['resblocks.3.alpha1.0']
$snake=Join-Path $repo 'src/models/Invoke-KokoroAdaInSnake.ps1'
$rows=foreach($case in $device.Comparisons){
    if($case.Case -cnotmatch '^[a-z-]+$'){throw 'Invalid case name'}
    $path=Join-Path $out ($case.Case+'.output.bin')
    if((Get-FileHash -LiteralPath $path).Hash -cne $case.OutputSHA256){throw 'Device output changed after comparison'}
    $observations=@()
    foreach($p in @($path,(Join-Path $FixtureDirectory ($case.Case+'.reference.bin')))){
        $bytes=[IO.File]::ReadAllBytes($p)
        if($bytes.Length -ne 32768){throw 'Unexpected consumer tensor shape'}
        $x=[float[]]::new(8192);[Buffer]::BlockCopy($bytes,0,$x,0,$bytes.Length)
        [float[]]$y=& $snake -InputTensor $x -Frames 64 -Channels 128 -Alpha $alpha
        $observations+=,$y
    }
    $max=0.0
    for($i=0;$i -lt 8192;$i++){$max=[Math]::Max($max,[Math]::Abs([double]$observations[0][$i]-$observations[1][$i]))}
    [ordered]@{Case=$case.Case;MaxAbsError=$max;Passed=($max -le 0.001)}
}
$summary=[ordered]@{Schema=1;Scope='pc_stock_snake_consumer_of_device_adain';
    LibrarySHA256=$device.LibrarySHA256;CheckpointSHA256=$weights.CheckpointSha256;
    Consumer='decoder.module.generator.resblocks.3.alpha1.0';
    Cases=@($rows);Passed=(@($rows|Where-Object {-not $_.Passed}).Count -eq 0)}
[IO.File]::WriteAllText($receiptPath,($summary|ConvertTo-Json -Depth 5))
if(-not $summary.Passed){throw 'Next-consumer gate failed'}
[pscustomobject]@{Passed=$true;Cases=@($rows).Count;Receipt=$receiptPath;
    MaxAbsError=($rows.MaxAbsError|Measure-Object -Maximum).Maximum}
