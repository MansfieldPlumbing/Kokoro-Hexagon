#requires -Version 7.7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClockDirectory,
    [Parameter(Mandatory)][string]$MeasurementPath,
    [Parameter(Mandatory)][string]$AudioDirectory,
    [string]$ImagePath = (Join-Path $PSScriptRoot '../build/student/image.clixml.gz')
)
$ErrorActionPreference = 'Stop'
$clock = (Resolve-Path -LiteralPath $ClockDirectory).Path
$measurement = (Resolve-Path -LiteralPath $MeasurementPath).Path
$audio = (Resolve-Path -LiteralPath $AudioDirectory).Path
$destination = [IO.Path]::GetFullPath($ImagePath)
$null = . "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition
& $studentOwner {
    param($clock, $measurement, $audio, $destination)
    $image = Open-StudentImage $destination
    $image.Changed = $false
    $parent = $image.Percepts['Boundary']
    function Add-Observation($node, $hash, $key, $source, $condition, $value) {
        $identity = "$($node.Identity)/$hash/$key"
        $record = [pscustomobject]@{Identity=$identity; Occurrence=$key; Provenance=$source; Condition=$condition; Measured=$value}
        $null = Add-StudentImageObservation $image $node.Identity $record Example
    }
    $path = Join-Path $clock 'zira-boundaries.csv'
    $hash = (Get-FileHash $path).Hash
    $node = New-StudentPercept $image 'Timing.Zira.WordOnset' 'TimingObservation' ([float[]](0,1,0,0)) $parent
    foreach ($row in (Import-Csv $path)) {
        Add-Observation $node $hash $row.Text "Microsoft Zira Desktop / $hash" $row.Mark ([double]$row.FirstToSecondOnsetMs)
    }
    $path = Join-Path $clock 'zira-transfer.clixml'
    $transfer = Import-Clixml $path
    Add-Observation $node (Get-FileHash $path).Hash 'PeriodMinusComma' $transfer.Teacher 'HeldOutWordOnsetDeltaMilliseconds' $transfer
    $path = Join-Path $clock 'boundary-results.csv'
    $hash = (Get-FileHash $path).Hash
    $node = New-StudentPercept $image 'Timing.Kokoro.MarkFrames' 'TimingObservation' ([float[]](0,1,0,0)) $parent
    foreach ($row in (Import-Csv $path)) {
        Add-Observation $node $hash $row.Text "Stock Kokoro af_heart / $hash" $row.Split ([int]$row.Frames)
    }
    $report = Import-Clixml $measurement
    $hash = (Get-FileHash $measurement).Hash
    $node = New-StudentPercept $image 'Performance.Generated.Acoustics' 'RecordingObservation' ([float[]](0,0,0,0)) $image.Percepts['Occurrence']
    foreach ($item in $report.Items) {
        $file = Join-Path $audio $item.RelativeInput
        if ((Get-FileHash -LiteralPath $file).Hash -cne $item.InputSHA256) { throw "Audio hash mismatch for $file" }
        $value = [pscustomobject]@{MeasurementSHA256=$hash; SourceSHA256=$item.InputSHA256; File=$item.RelativeInput; MedianF0Hz=$item.MedianF0Hz; Gaps=$item.Gaps; FrameHop=$item.FrameHop; AnalysisRate=$item.AnalysisRate; Scope=$report.Scope; Alignment=$item.Transcript.Alignment}
        Add-Observation $node $hash $item.Identity $file 'Generated performance, audio-only measurements' $value
    }
    if ($image.Changed) { $null = Save-StudentImage $image $destination }
    $restored = Open-StudentImage $destination
    foreach ($identity in $image.Evidence.Keys) {
        if (!$restored.Evidence.ContainsKey($identity)) { throw "Missing evidence after reload: $identity" }
    }
    [pscustomobject]@{Path=$destination; SHA256=(Get-FileHash $destination).Hash; Evidence=$restored.Evidence.Count; Percepts=$restored.Percepts.Count}
} $clock $measurement $audio $destination
