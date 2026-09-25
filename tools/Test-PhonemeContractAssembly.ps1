#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AssemblyPath, [string]$VoicePath)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$sourcePath = [IO.Path]::Combine($root, 'src', 'text', 'Kokoro.PhonemeExpression.ps1')
$source = & ([scriptblock]::Create([IO.File]::ReadAllText($sourcePath))) $root
$expected = & $source.Verify
$config = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'lib', 'kokoro-v1_0.config.json')) |
    ConvertFrom-Json -AsHashtable
$assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path)
$type = $assembly.GetType('Kokoro.Phonemes.Contract', $true)
$admit = $type.GetMethod('Ids')
$row = $type.GetMethod('VoiceRowIndex')
$hash = [string]$type.GetMethod('VocabularySHA256').Invoke($null, @())
if ($hash -cne $expected.SourceSHA256) { throw 'The persisted vocabulary hash differs from the pinned source.' }
foreach ($entry in $config.vocab.GetEnumerator()) {
    $actual = [int[]]$admit.Invoke($null, [object[]]@([string]$entry.Key))
    if (($actual -join ',') -cne "0,$([int]$entry.Value),0") {
        throw 'A persisted phoneme ID differs from the pinned vocabulary.'
    }
}
$limit = [int[]]$admit.Invoke($null, [object[]]@(('a' * 510)))
if ($limit.Length -ne 512 -or [int]$row.Invoke($null, [object[]]@(510)) -ne 509) {
    throw 'The persisted length or voice-row boundary is incorrect.'
}
foreach ($invalid in @($null, '', '🙂', ('a' * 511))) {
    $rejected = $false
    try { $null = $admit.Invoke($null, [object[]]@($invalid)) }
    catch {
        if ($_.Exception.GetBaseException() -isnot [ArgumentException]) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Invalid phonemes were admitted.' }
}
$resourceName = $null
if ($VoicePath) {
    $manifest = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'lib', 'manifest.json')) |
        ConvertFrom-Json -AsHashtable
    $voiceName = [IO.Path]::GetFileName($VoicePath)
    $pin = @($manifest.model.files | Where-Object { $_.path -ceq "voices\$voiceName" })
    if ($pin.Count -ne 1) { throw 'The voice pack is not pinned.' }
    $readerPath = [IO.Path]::Combine($root, 'src', 'runspace', 'Torch.Checkpoint.psm1')
    $reader = [scriptblock]::Create([IO.File]::ReadAllText($readerPath)).InvokeReturnAsIs()
    $archive = & $reader.ReadTensor $VoicePath $pin[0].sha256
    $expectedVoice = & $reader.Bytes $archive 'value'
    $resourceName = 'Kokoro.Voices.' + [IO.Path]::GetFileNameWithoutExtension($voiceName) + '.f32'
    $resource = $assembly.GetManifestResourceStream($resourceName)
    if ($null -eq $resource) { throw 'The voice tensor is missing from the persisted DLL.' }
    try {
        $actualVoice = [byte[]]::new($expectedVoice.Length)
        $resource.ReadExactly($actualVoice, 0, $actualVoice.Length)
        if ($resource.ReadByte() -ne -1 -or
            -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedVoice, $actualVoice)) {
            throw 'The persisted voice tensor differs from the pinned checkpoint.'
        }
    }
    finally { $resource.Dispose() }
}
[pscustomobject]@{
    WindowsLoad = $true
    Assembly = $assembly.GetName().Name
    TestedPhonemes = $config.vocab.Count
    MaxPhonemes = 510
    VocabularySHA256 = $hash
    Bytes = (Get-Item -LiteralPath $AssemblyPath).Length
    VoiceResource = $resourceName
}
