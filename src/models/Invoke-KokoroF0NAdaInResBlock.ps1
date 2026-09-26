#requires -Version 7.4
# Compatibility entry point for F0/N predictor blocks. The stock AdaIN
# residual operation is shared with the decoder.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][float[]] $InputTensor,
    [Parameter(Mandatory)][float[]] $Style,
    [Parameter(Mandatory)][System.Collections.IDictionary] $Parameters,
    [Parameter(Mandatory)][ValidateRange(2, 32768)][int] $Frames,
    [Parameter(Mandatory)][ValidateRange(1, 1024)][int] $Channels,
    [ValidateRange(0, 1024)][int] $OutputChannels = 0,
    [switch] $Upsample
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Invoke-KokoroAdaInResBlock1d.ps1') `
    -InputTensor $InputTensor -Style $Style -Parameters $Parameters `
    -Frames $Frames -Channels $Channels -OutputChannels $OutputChannels `
    -Upsample:$Upsample
