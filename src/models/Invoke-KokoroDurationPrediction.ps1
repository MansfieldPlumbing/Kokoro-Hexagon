#requires -Version 7.4
# Stock Kokoro duration projection followed by sigmoid, sum, speed, round,
# clamp, and frame-to-token map. Kokoro model.py forward_with_tokens at
# dfb907a02bba8152ca444717ca5d78747ccb4bec.
# Input is the 512-channel output of predictor.lstm, batch one.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $LstmOutput,
    [Parameter(Mandatory)][float[]] $Weights,
    [Parameter(Mandatory)][float[]] $Bias,
    [Parameter(Mandatory)][ValidateRange(1, 512)][int] $TokenCount,
    [Parameter(Mandatory)][ValidateRange(0.001, 100)][double] $Speed,
    [ValidateRange(1, 65536)][int] $MaxFrames = 65536
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
[float[]]$logits = & (Join-Path $root 'Invoke-KokoroLinear.ps1') `
    -InputTensor $LstmOutput -Weights $Weights -Bias $Bias `
    -Rows $TokenCount -InputChannels 512 -OutputChannels 50
& (Join-Path $root 'New-KokoroDurationMap.ps1') -DurationLogits $logits `
    -TokenCount $TokenCount -Speed $Speed -MaxFrames $MaxFrames
