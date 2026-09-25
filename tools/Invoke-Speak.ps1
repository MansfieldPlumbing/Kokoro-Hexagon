#requires -Version 7.4
# Stage front + generator contexts and one phrase, run Speak.ps1 on the S23 (plays through the speaker), return the receipt.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Front,
    [Parameter(Mandatory)][string] $Gen,
    [Parameter(Mandatory)][string] $PhraseDir,        # in_*.f32, oracle_audio.f32
    [int] $ValidFrameCount,                            # asr frames L
    [double] $MinSnrDb = 20,
    [ValidateRange(0, 1000)][int] $Repeat = 0,
    [ValidateRange(1, 100)][int] $PlaybackRepeat = 1,
    [string] $StageRoot = (Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\stage'),
    [string] $Serial = $env:KOKORO_QNN_SERIAL,
    [string] $QnnSystem = $env:KOKORO_QNN_SYSTEM_LIB,
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)
$ErrorActionPreference = 'Stop'
if (-not $Serial) { throw 'A device serial is required through -Serial or KOKORO_QNN_SERIAL.' }
if (-not $QnnSystem -or -not (Test-Path -LiteralPath $QnnSystem -PathType Leaf)) {
    throw 'A readable QnnSystem library is required through -QnnSystem or KOKORO_QNN_SYSTEM_LIB.'
}
$adb = if ($env:KOKORO_QNN_ADB) { $env:KOKORO_QNN_ADB } else { 'adb' }; $nl = [Environment]::NewLine
$st = Join-Path $StageRoot 'job-speak'; [void](New-Item -ItemType Directory -Force $st)
Copy-Item $Front (Join-Path $st 'front.bin') -Force; Copy-Item $Gen (Join-Path $st 'gen.bin') -Force
$reader = Join-Path $PSScriptRoot 'Read-QnnContextInfo.ps1'
$describe = {
    param([string]$Name, [string]$Bin, [string]$FirstInput)
    $m = & $reader -QnnSystem $QnnSystem -ContextPath (Join-Path $st $Bin)
    $in = @($m.Tensors | Where-Object Dir -eq 'in' | Sort-Object { if ($_.Name -eq $FirstInput) { 0 } else { 1 } })
    $o = $m.Tensors | Where-Object Dir -eq 'out'
    [long]$b = 4; foreach ($x in $o.Dims) { $b *= $x }
    $ins = foreach ($t in $in) { "@{ Id=$($t.Id); Name='$($t.Name)'; Shape=[int[]]@($($t.Dims -join ',')) }" }
    [pscustomobject]@{
        Text  = "@{ Name='$Name'; Context='$Bin'; GraphName='$($m.Graph)'; Inputs=@(" + ($ins -join ', ') + "); Output=@{ Id=$($o.Id); Name='$($o.Name)'; Shape=[int[]]@($($o.Dims -join ',')); Bytes=$b } }"
        Names = @($in.Name)
    }
}
$f = & $describe 'front' 'front.bin' ''
$g = & $describe 'gen' 'gen.bin' 'x0'
$files = foreach ($n in ($f.Names + $g.Names | Where-Object { $_ -ne 'x0' } | Sort-Object -Unique)) {
    Copy-Item (Join-Path $PhraseDir "in_$n.f32") $st -Force; "'$n'='in_$n.f32'"
}
Copy-Item (Join-Path $PhraseDir 'oracle_audio.f32') $st -Force
$job = "[pscustomobject]@{ Name='kokoro-speak'; MinSnrDb=$MinSnrDb; Repeat=$Repeat; PlaybackRepeat=$PlaybackRepeat; ValidFrames=$($ValidFrameCount * 120 + 4); ValidSamples=$($ValidFrameCount * 600); Oracle='oracle_audio.f32'$nl" +
       "    Files=@{ " + ($files -join '; ') + " }$nl    Front=$($f.Text)$nl    Gen=$($g.Text) }"
Set-Content (Join-Path $st 'speak-job.ps1') $job
Copy-Item (Join-Path $PSScriptRoot '..\src\runspace\Speak.ps1') $st -Force
Copy-Item (Join-Path $PSScriptRoot '..\src\runspace\Audio.AAudio.psm1') $st -Force

$names = (Get-ChildItem $st -File).Name
foreach ($n in $names) { [void](& $adb -s $Serial push (Join-Path $st $n) "/data/local/tmp/kokoro-fl/$n") }
$steps = [Collections.Generic.List[string]]::new()
foreach ($n in $names) { $steps.Add("run-as $Package cp /data/local/tmp/kokoro-fl/$n files/kokoro-fl/$n") }
$steps.Add("run-as $Package mkdir -p files/kokoro-fl/modules")
$steps.Add("run-as $Package cp files/kokoro-fl/Audio.AAudio.psm1 files/kokoro-fl/modules/Audio.AAudio.psm1")
$steps.Add("run-as $Package cp files/kokoro-fl/Speak.ps1 files/Start.ps1")
$steps.Add("run-as $Package cp files/kokoro-fl/Speak.ps1 files/PROFILE.PS1")
$steps.Add("run-as $Package truncate -s 0 files/kokoro-fl/receipt.txt")
$steps.Add("am force-stop $Package")
$steps.Add("monkey -p $Package -c android.intent.category.LAUNCHER 1")
[void](& $adb -s $Serial shell ($steps -join '; ') 2>&1)
$r = $null
foreach ($i in 1..120) {
    Start-Sleep -Seconds 2
    $r = & $adb -s $Serial shell run-as $Package cat files/kokoro-fl/receipt.txt 2>$null
    if (($r -join "`n") -match 'Job=kokoro-speak' -and ($r -join "`n") -match 'Passed=') { break }
}
"front sha=$((Get-FileHash $Front).Hash.Substring(0,16)) gen sha=$((Get-FileHash $Gen).Hash.Substring(0,16))"
$r
