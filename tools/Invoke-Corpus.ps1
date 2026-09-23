#requires -Version 7.4
# Run a benchmark corpus on the device: each phrase through the smallest capacity bucket that fits,
# repeated warm timing per phrase, speaker playback, then aggregate RTF across the corpus.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CorpusDir,                       # one folder per phrase, each with phrase.json + in_*.f32
    [Parameter(Mandatory)][string] $CandidateRoot,                   # holds c64/, c96/, c128/ ... and the 160 baseline
    [string] $BaselineDir = 'C:\Dev\Build\Kokoro-QNN\baseline-fp16-20260922',
    [int] $Repeat = 10,
    [double] $MinSnrDb = 12,
    [string] $ReceiptPath
)
$ErrorActionPreference = 'Stop'
$speak = Join-Path $PSScriptRoot 'Invoke-Speak.ps1'

function Get-BucketContexts([int] $Capacity) {
    if ($Capacity -eq 160) {
        return @{ Front = Join-Path $BaselineDir 'front_c160_fp16.bin'; Gen = Join-Path $BaselineDir 'gen_nin_gb_c160_fp16_vtcm8.bin' }
    }
    $dir = Join-Path $CandidateRoot "c$Capacity"
    @{
        Front = Join-Path $dir "front\front_c$($Capacity)_mul_ctx_qnn.bin"
        Gen   = Join-Path $dir "gen\gen_c$($Capacity)_banal_ctx_qnn.bin"
    }
}

$rows = foreach ($dir in (Get-ChildItem $CorpusDir -Directory | Sort-Object Name)) {
    $manifest = Join-Path $dir.FullName 'phrase.json'
    if (-not (Test-Path $manifest)) { continue }
    $p = Get-Content $manifest -Raw | ConvertFrom-Json
    $ctx = Get-BucketContexts ([int]$p.capacity)
    if (-not (Test-Path $ctx.Front) -or -not (Test-Path $ctx.Gen)) { Write-Warning "missing contexts for capacity $($p.capacity) ($($p.id))"; continue }
    $adb = if ($env:KOKORO_QNN_ADB) { $env:KOKORO_QNN_ADB } else { 'adb' }
    $out = $null
    foreach ($attempt in 1..2) {
        $state = (& $adb -s $env:KOKORO_QNN_SERIAL get-state 2>&1) -join ''
        if ($state -notmatch 'device') { Write-Warning "$($p.id): device state '$state'; waiting"; & $adb -s $env:KOKORO_QNN_SERIAL wait-for-device 2>&1 | Out-Null }
        $out = & $speak -Front $ctx.Front -Gen $ctx.Gen -PhraseDir $dir.FullName -ValidFrameCount ([int]$p.validFrames) -Repeat $Repeat -MinSnrDb $MinSnrDb 2>&1
        if (($out | Out-String) -match 'Passed=True') { break }
        Write-Warning "$($p.id): attempt $attempt did not pass; retrying"
    }
    $text = ($out | Out-String)
    $get = { param([string]$pattern) if ($text -match $pattern) { [double]$Matches[1] } else { [double]::NaN } }
    $seconds = [double]$p.validSamples / 24000.0
    [pscustomobject]@{
        Id = $p.id; Capacity = [int]$p.capacity; Frames = [int]$p.validFrames; Seconds = $seconds
        FrontMs = & $get 'BenchFront N=\d+ MeanMs=([\d.]+)'
        GenMs   = & $get 'BenchGen N=\d+ MeanMs=([\d.]+)'
        GenP95  = & $get 'BenchGen N=\d+ MeanMs=[\d.]+ P50Ms=[\d.]+ P95Ms=([\d.]+)'
        ColdFrontMs = & $get 'FrontMs=([\d.]+)'
        ColdGenMs   = & $get 'GenMs=([\d.]+)'
        SnrDb   = & $get 'AudioSnrDb=(-?[\d.]+)'
        Played  = $text -match 'PlaybackComplete=True'
        Passed  = $text -match 'Passed=True'
    }
}

$rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
$ok = @($rows | Where-Object { $_.Passed })
if ($ok.Count) {
    $rtf = $ok | ForEach-Object { $_.GenMs / 1000.0 / $_.Seconds }
    $sorted = $rtf | Sort-Object
    $mean = ($rtf | Measure-Object -Average).Average
    $audio = ($ok | Measure-Object Seconds -Sum).Sum
    $firstPcm = $ok | ForEach-Object { $_.ColdFrontMs + $_.ColdGenMs }
    $summary = [pscustomobject]@{
        Phrases = $ok.Count; AudioSeconds = [math]::Round($audio, 2)
        GeneratorRtfMean = [math]::Round($mean, 4)
        GeneratorRtfP50 = [math]::Round($sorted[[int](0.5 * ($sorted.Count - 1))], 4)
        GeneratorRtfP95 = [math]::Round($sorted[[int](0.95 * ($sorted.Count - 1))], 4)
        GeneratorRtfMax = [math]::Round($sorted[-1], 4)
        PreparedToAudioMeanMs = [math]::Round((($firstPcm | Measure-Object -Average).Average), 1)
        SnrMeanDb = [math]::Round((($ok | Measure-Object SnrDb -Average).Average), 2)
        AllPlayed = -not ($ok | Where-Object { -not $_.Played })
    }
    $summary | Format-List | Out-String | Write-Host
    if ($ReceiptPath) {
        $lines = @('# Corpus benchmark', '', ($rows | Format-Table -AutoSize | Out-String -Width 160), '', ($summary | Format-List | Out-String))
        Set-Content $ReceiptPath ($lines -join "`n")
    }
}
