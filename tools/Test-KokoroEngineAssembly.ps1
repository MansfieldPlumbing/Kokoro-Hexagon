#requires -Version 7.4
# Verify the consolidated downstream model assembly contract and resources.
[CmdletBinding()]
param([Parameter(Mandatory)][string] $AssemblyPath)

Set-StrictMode -Version Latest
$resolved = (Resolve-Path -LiteralPath $AssemblyPath).Path
$stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
$reader = [Reflection.PortableExecutable.PEReader]::new($stream)
try {
    $cor = $reader.PEHeaders.CorHeader
    if ($null -eq $cor -or
        -not (($cor.Flags -band [Reflection.PortableExecutable.CorFlags]::ILOnly) -ne 0) -or
        $cor.ManagedNativeHeaderDirectory.Size -ne 0) {
        throw 'The downstream model assembly is not an IL-only image.'
    }
}
finally { $reader.Dispose(); $stream.Dispose() }
$assembly = [Reflection.Assembly]::LoadFrom($resolved)
if ($assembly.GetName().Name -cne 'Dev.MansfieldPlumbing.Kokoro.Model') {
    throw 'The downstream model assembly identity differs.'
}
$type = $assembly.GetType('Dev.MansfieldPlumbing.Kokoro.Model.Contract', $true)
if ([int]$type.GetMethod('ModelContractVersion').Invoke($null, @()) -ne 1 -or
    [bool]$type.GetMethod('SynthesisReady').Invoke($null, @()) -or
    $null -ne $type.GetMethod('SynthesizePhonemes')) {
    throw 'The incomplete downstream model contract admitted synthesis.'
}
$ids = [int[]]$type.GetMethod('Ids').Invoke($null, [object[]]@('a'))
$row = [int]$type.GetMethod('VoiceRowIndex').Invoke($null, [object[]]@(1))
if (($ids -join ',') -cne '0,43,0' -or $row -ne 0) {
    throw 'The downstream model phoneme contract differs.'
}
$resources = @($assembly.GetManifestResourceNames())
if (@($resources | Where-Object { $_ -like 'Kokoro.Weight.*' }).Count -ne 548 -or
    'Kokoro.WeightIndex.json' -notin $resources -or
    'Kokoro.EngineContract.json' -notin $resources -or
    @($resources | Where-Object { $_ -like 'Kokoro.Voices.*.f32' }).Count -ne 1) {
    throw 'The downstream model resource topology differs.'
}
$contractStream = $assembly.GetManifestResourceStream('Kokoro.EngineContract.json')
try {
    $reader = [IO.StreamReader]::new($contractStream, [Text.Encoding]::UTF8, $false, 1024, $true)
    try { $contract = $reader.ReadToEnd() | ConvertFrom-Json }
    finally { $reader.Dispose() }
}
finally { $contractStream.Dispose() }
if ($contract.synthesis_ready -or $contract.graph_complete -or $contract.tensor_count -ne 548) {
    throw 'The persisted downstream engine receipt overstates completion.'
}

[pscustomobject]@{
    Passed = $true
    Assembly = $assembly.GetName().Name
    Bytes = (Get-Item -LiteralPath $resolved).Length
    SHA256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    TensorCount = 548
    VoiceResource = [string]$contract.voice_resource
    GraphSHA256 = [string]$contract.graph_sha256
    SynthesisReady = $false
}
