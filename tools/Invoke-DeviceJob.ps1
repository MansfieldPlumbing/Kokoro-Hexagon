#requires -Version 7.4
# Stage a context binary + oracles, generate job.ps1 from the binary's own metadata, run on the S23 via AndroidSMA, return the receipt.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Context,          # compiled *_ctx_qnn.bin
    [Parameter(Mandatory)][string] $OraclePrefix,     # e.g. oracle_r_  (files <dir>\<prefix><outputName>.f32)
    [string] $InputDir,
    [double] $MinSnrDb = 30,
    [string] $StageRoot = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\stage'),
    [string] $Serial = $env:KOKORO_QNN_SERIAL,
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)
$ErrorActionPreference = 'Stop'
$adb = if ($env:KOKORO_QNN_ADB) { $env:KOKORO_QNN_ADB } else { 'adb' }
$name = [IO.Path]::GetFileNameWithoutExtension($Context) -replace '_ctx_qnn$', ''
$st = Join-Path $StageRoot "job-$name"
[void](New-Item -ItemType Directory -Force $st)
Copy-Item $Context (Join-Path $st 'model.bin') -Force
$meta = & (Join-Path $PSScriptRoot 'Read-QnnContextInfo.ps1') -QnnSystem $env:KOKORO_QNN_SYSTEM_LIB -ContextPath (Join-Path $st 'model.bin')
$nl = [Environment]::NewLine
$ins = foreach ($t in ($meta.Tensors | Where-Object Dir -eq 'in')) {
    Copy-Item (Join-Path $InputDir "in_$($t.Name).f32") $st -Force
    "@{ Id=$($t.Id); Name='$($t.Name)'; Shape=[int[]]@($($t.Dims -join ',')); File='in_$($t.Name).f32' }"
}
$outs = foreach ($t in ($meta.Tensors | Where-Object Dir -eq 'out')) {
    [long]$b = 4; foreach ($x in $t.Dims) { $b *= $x }
    Copy-Item (Join-Path (Split-Path $Context) "$OraclePrefix$($t.Name).f32") (Join-Path $st "oracle_$($t.Name).f32") -Force
    "@{ Id=$($t.Id); Name='$($t.Name)'; Shape=[int[]]@($($t.Dims -join ',')); File='out_$($t.Name).f32'; Bytes=$b; Oracle='oracle_$($t.Name).f32' }"
}
$job = "[pscustomobject]@{ Name='$name'; Context='model.bin'; GraphName='$($meta.Graph)'; MinSnrDb=$MinSnrDb$nl    Inputs=@($nl        " +
       ($ins -join ",$nl        ") + ")$nl    Outputs=@($nl        " + ($outs -join ",$nl        ") + ") }"
Set-Content (Join-Path $st 'job.ps1') $job
Copy-Item (Join-Path $PSScriptRoot '..\src\runspace\FirstLight.ps1') $st -Force

$files = (Get-ChildItem $st -File).Name
foreach ($f in $files) { [void](& $adb -s $Serial push (Join-Path $st $f) "/data/local/tmp/kokoro-fl/$f") }
$steps = [Collections.Generic.List[string]]::new()
foreach ($f in $files) { $steps.Add("run-as $Package cp /data/local/tmp/kokoro-fl/$f files/kokoro-fl/$f") }
$steps.Add("run-as $Package cp files/kokoro-fl/FirstLight.ps1 files/Start.ps1")
$steps.Add("run-as $Package cp files/kokoro-fl/FirstLight.ps1 files/PROFILE.PS1")
$steps.Add("run-as $Package truncate -s 0 files/kokoro-fl/receipt.txt")
$steps.Add("am force-stop $Package")
$steps.Add("monkey -p $Package -c android.intent.category.LAUNCHER 1")
[void](& $adb -s $Serial shell ($steps -join '; ') 2>&1)
$r = $null
foreach ($i in 1..90) {
    Start-Sleep -Seconds 2
    $r = & $adb -s $Serial shell run-as $Package cat files/kokoro-fl/receipt.txt 2>$null
    if (($r -join "`n") -match "Job=$name" -and ($r -join "`n") -match 'Passed=') { break }
}
"context sha=$((Get-FileHash $Context).Hash.Substring(0,16)) job=$name"
$r
