#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Checkout,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$ResidentPayloads
)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Choose a new emission directory.' }
$destination = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
. (Join-Path $Checkout 'Invoke-HexagonDevelopment.ps1')
. (Join-Path $Checkout 'src/jobs/Kokoro.Generator60x16Run.ps1')
$options = @{
    Frames = 56521
    BatchTiles = 4
    HvxThreads = 4
    AdaInMode = 'Constants'
    Tail = $true
    Front = $true
    Whole = $true
    Source = $true
    Schedule = 'Backward'
    SpanTiles = 120
    SeededNoise = $true
    WeightPlanes = 1
    ResidentSourceChannels = @(128,256)
    AsyncWeights = $true
    HostCoefficients = $true
    VectorPackets = $true
    PowerVotes = @('HvxPower','CoreMax','HmxPower')
}
$job = New-KokoroGenerator60x16RunSteps @options
$steps = $job.Steps
if ($ResidentPayloads) {
    . (Join-Path $Checkout 'src/jobs/Kokoro.ResidentPayload.ps1')
    $steps = Add-KokoroResidentPayloadEntry -Steps $steps -Layout $job.Layout
}
$definition = @{
    Steps = $steps
    Symbol = 'kokoro_generator_tail_skel_handle_invoke'
    Soname = 'libkokoro_generator_tail_skel.so'
}
$null = Invoke-HexagonEmission -Kernel Definition -Definition $definition -OutputDirectory $destination
$layout = [pscustomobject]$job.Layout | Select-Object PcmOffset,Tiles,OutputBytes,Samples,InputBytes,@{Name='Speech';Expression={'True'}},@{Name='Runs';Expression={9}}
if ($ResidentPayloads) { $layout | Add-Member -NotePropertyName ResidentPayloads -NotePropertyValue $true }
$layout | ConvertTo-Json | Set-Content (Join-Path $destination 'runner-layout.json')
Get-FileHash (Join-Path $destination $definition.Soname)
