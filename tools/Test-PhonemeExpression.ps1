#requires -Version 7.4
[CmdletBinding()]
param([string]$VoicePath)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$path = [IO.Path]::Combine($root, 'src', 'text', 'Kokoro.PhonemeExpression.ps1')
$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'The phoneme expression source does not parse.' }
$contract = & ([scriptblock]::Create([IO.File]::ReadAllText($path))) $root
$receipt = & $contract.Verify

if ($VoicePath) {
    $readerPath = [IO.Path]::Combine($root, 'src', 'runspace', 'Torch.Checkpoint.psm1')
    $reader = [scriptblock]::Create([IO.File]::ReadAllText($readerPath)).InvokeReturnAsIs()
    $manifest = [IO.File]::ReadAllText([IO.Path]::Combine($root, 'lib', 'manifest.json')) |
        ConvertFrom-Json -AsHashtable
    $name = [IO.Path]::GetFileName($VoicePath)
    $pin = @($manifest.model.files | Where-Object { $_.path -ceq "voices\$name" })
    if ($pin.Count -ne 1) { throw 'The voice pack is not pinned in the model manifest.' }
    $archive = & $reader.ReadTensor $VoicePath $pin[0].sha256
    $tensor = $archive.Tensors['value']
    if (($tensor.Shape -join ',') -cne '510,1,256' -or $tensor.DType -cne 'float32') {
        throw 'The pinned voice pack does not have the expected 510 x 1 x 256 float32 shape.'
    }
    $first = & $reader.TensorRow $archive 0
    $last = & $reader.TensorRow $archive 509
    if ($first.Length -ne 1024 -or $last.Length -ne 1024) { throw 'Voice rows must be 256 float32 values.' }
    if ($name -ceq 'af_heart.pt') {
        $firstHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($first))
        $lastHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($last))
        if ($firstHash -cne '76F9BF663F6F2C845D8ED893B277DF8F8D7069D8A965281E93FCDF7FD3BE84A8' -or
            $lastHash -cne '88B4B4859B90ADA6111FCF7E4A428E17BFFDD64BFD022727A650F7832D174054') {
            throw 'Pinned af_heart voice rows differ from the read-only reference probe.'
        }
    }
    $receipt | Add-Member -NotePropertyName VoiceShape -NotePropertyValue '510,1,256'
    $receipt | Add-Member -NotePropertyName VoiceRows -NotePropertyValue 510
}
$receipt
