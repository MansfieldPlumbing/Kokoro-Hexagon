#requires -Version 7.4
# Stage capacity-specific contexts and phrase bundles, run the overlap pipeline, and return its device receipt.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][hashtable] $Buckets, # capacity -> @{ Front='...'; Gen='...' }
    [Parameter(Mandatory)][string[]] $PhraseDirs,
    [double] $MinSnrDb = 20,
    [string] $StageRoot = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\stage'),
    [string] $Serial = $env:KOKORO_QNN_SERIAL,
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)
$ErrorActionPreference='Stop'
if (-not $Serial) { throw 'KOKORO_QNN_SERIAL or -Serial is required.' }
if (-not $env:KOKORO_QNN_SYSTEM_LIB) { throw 'KOKORO_QNN_SYSTEM_LIB is required.' }
$adb=if($env:KOKORO_QNN_ADB){$env:KOKORO_QNN_ADB}else{'adb'}; $nl=[Environment]::NewLine
$st=Join-Path $StageRoot 'job-pipeline'; [void](New-Item -ItemType Directory -Force $st)
$reader=Join-Path $PSScriptRoot 'Read-QnnContextInfo.ps1'
$describe={ param([string]$Name,[string]$File,[string]$First)
    $m=& $reader -QnnSystem $env:KOKORO_QNN_SYSTEM_LIB -ContextPath (Join-Path $st $File)
    $inputs=@($m.Tensors|Where-Object Dir -eq 'in'|Sort-Object {if($_.Name -eq $First){0}else{1}})
    $output=@($m.Tensors|Where-Object Dir -eq 'out'); if($output.Count -ne 1){throw "$Name must have one output"}; $o=$output[0]
    [long]$bytes=4; foreach($d in $o.Dims){$bytes*=$d}
    $ins=foreach($t in $inputs){"[pscustomobject]@{Id=$($t.Id);Name='$($t.Name)';Shape=[int[]]@($($t.Dims -join ','))}"}
    [pscustomobject]@{Names=@($inputs.Name);Text="[pscustomobject]@{Name='$Name';Context='$File';GraphName='$($m.Graph)';Inputs=@("+($ins -join ',')+");Output=[pscustomobject]@{Id=$($o.Id);Name='$($o.Name)';Shape=[int[]]@($($o.Dims -join ','));Bytes=$bytes}}"}
}
$bucketText=[Collections.Generic.List[string]]::new(); $bucketInputs=@{}
foreach($capacity in @($Buckets.Keys|Sort-Object {[int]$_})){
    $entry=$Buckets[$capacity]; $frontName="c$capacity-front.bin"; $genName="c$capacity-gen.bin"
    Copy-Item -LiteralPath $entry.Front -Destination (Join-Path $st $frontName) -Force
    Copy-Item -LiteralPath $entry.Gen -Destination (Join-Path $st $genName) -Force
    $front=& $describe "front-c$capacity" $frontName ''; $gen=& $describe "gen-c$capacity" $genName 'x0'
    $bucketInputs[[string]$capacity]=@($front.Names+$gen.Names|Where-Object {$_ -ne 'x0'}|Sort-Object -Unique)
    $bucketText.Add("[pscustomobject]@{Capacity=$capacity;Front=$($front.Text);Gen=$($gen.Text)}")
}
$phraseText=[Collections.Generic.List[string]]::new()
foreach($dir in $PhraseDirs){
    $manifest=Get-Content -Raw -LiteralPath (Join-Path $dir 'phrase.json')|ConvertFrom-Json
    if($manifest.id -notmatch '^[A-Za-z0-9_-]+$'){throw "unsafe phrase id '$($manifest.id)'"}
    $speaker=if($manifest.PSObject.Properties.Name -contains 'speaker'){$manifest.speaker}else{'narrator'}
    $voice=if($manifest.PSObject.Properties.Name -contains 'voice'){$manifest.voice}else{'unknown'}
    if($speaker -notmatch '^[\p{L}\p{N}][\p{L}\p{N}_.-]{0,63}$'){throw "unsafe speaker id '$speaker'"}
    if($voice -notmatch '^[a-z][a-z0-9_]{0,63}$'){throw "unsafe voice id '$voice'"}
    if(-not $Buckets.ContainsKey([int]$manifest.capacity) -and -not $Buckets.ContainsKey([string]$manifest.capacity)){throw "no bucket for phrase capacity $($manifest.capacity)"}
    $files=[Collections.Generic.List[string]]::new()
    foreach($name in $bucketInputs[[string]$manifest.capacity]){
        $source=Join-Path $dir "in_$name.f32"; if(-not(Test-Path -LiteralPath $source)){throw "missing $source"}
        $dest="p-$($manifest.id)-in_$name.f32"; Copy-Item -LiteralPath $source -Destination (Join-Path $st $dest) -Force; $files.Add("'$name'='$dest'")
    }
    $oracle="p-$($manifest.id)-oracle.f32"; Copy-Item -LiteralPath (Join-Path $dir 'oracle_audio.f32') -Destination (Join-Path $st $oracle) -Force
    $phraseText.Add("[pscustomobject]@{Id='$($manifest.id)';Speaker='$speaker';Voice='$voice';Capacity=$($manifest.capacity);ValidSamples=$($manifest.validSamples);Oracle='$oracle';Files=@{$($files -join ';')}}")
}
$job="[pscustomobject]@{MinSnrDb=$MinSnrDb;Buckets=@($($bucketText -join ','));Phrases=@($($phraseText -join ','))}"
Set-Content -LiteralPath (Join-Path $st 'pipeline-job.ps1') -Value $job
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\runspace\Pipeline.ps1') -Destination $st -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src\runspace\Audio.AAudio.psm1') -Destination $st -Force
$names=@(Get-ChildItem -LiteralPath $st -File|Select-Object -ExpandProperty Name)
foreach($name in $names){& $adb -s $Serial push (Join-Path $st $name) "/data/local/tmp/kokoro-fl/$name"|Out-Null;if($LASTEXITCODE){throw "adb push failed: $name"}}
$steps=[Collections.Generic.List[string]]::new(); foreach($name in $names){$steps.Add("run-as $Package cp /data/local/tmp/kokoro-fl/$name files/kokoro-fl/$name")}
$steps.Add("run-as $Package cp files/kokoro-fl/Audio.AAudio.psm1 files/kokoro-fl/modules/Audio.AAudio.psm1")
$steps.Add("run-as $Package cp files/kokoro-fl/Pipeline.ps1 files/Start.ps1");$steps.Add("run-as $Package cp files/kokoro-fl/Pipeline.ps1 files/PROFILE.PS1");$steps.Add("run-as $Package truncate -s 0 files/kokoro-fl/receipt.txt");$steps.Add("am force-stop $Package");$steps.Add("monkey -p $Package -c android.intent.category.LAUNCHER 1")
& $adb -s $Serial shell ($steps -join '; ')|Out-Null;if($LASTEXITCODE){throw 'device staging or launch failed'}
$receipt=$null; foreach($i in 1..180){Start-Sleep -Seconds 2;$receipt=& $adb -s $Serial shell run-as $Package cat files/kokoro-fl/receipt.txt 2>$null;if(($receipt -join "`n") -match 'Job=kokoro-pipeline' -and ($receipt -join "`n") -match 'Passed='){break}}
$receipt
