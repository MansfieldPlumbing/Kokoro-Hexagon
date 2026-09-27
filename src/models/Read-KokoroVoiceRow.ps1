#requires -Version 7.4
# Stock pipeline voice selection: pack[len(phonemes)-1].
# kokoro/pipeline.py at dfb907a02bba8152ca444717ca5d78747ccb4bec.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $VoicePath,
    [Parameter(Mandatory)][ValidateRange(1, 510)][int] $PhonemeCount
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$pin = @(([IO.File]::ReadAllText((Join-Path $root 'lib/manifest.json')) |
    ConvertFrom-Json -AsHashtable).model.files | Where-Object {
        $_.path -ceq 'voices\af_heart.pt'
    })
$path = (Resolve-Path -LiteralPath $VoicePath).Path
if ($pin.Count -ne 1 -or (Get-Item -LiteralPath $path).Length -ne [long]$pin[0].bytes -or
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $pin[0].sha256) {
    throw 'Selected voice does not match the pinned digest.'
}
$reader = [scriptblock]::Create([IO.File]::ReadAllText(
    (Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
$archive = & $reader.ReadTensor $path $pin[0].sha256
$tensor = $archive.Tensors['value']
if ($null -eq $tensor -or $tensor.DType -cne 'float32' -or
    ($tensor.Shape -join ',') -cne '510,1,256' -or
    $PhonemeCount -gt $tensor.Shape[0]) {
    throw 'Voice row shape or requested phoneme count is invalid.'
}
[byte[]]$bytes = & $reader.TensorRow $archive ($PhonemeCount - 1)
if ($bytes.Length -ne 1024) { throw 'Voice row byte count differs.' }
$row = [float[]]::new(256)
[Buffer]::BlockCopy($bytes, 0, $row, 0, $bytes.Length)
foreach ($value in $row) {
    if (-not [float]::IsFinite($value)) { throw 'Voice row is non-finite.' }
}
Write-Output -NoEnumerate $row
