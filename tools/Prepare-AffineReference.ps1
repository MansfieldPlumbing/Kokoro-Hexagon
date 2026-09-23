#requires -Version 7.4
# Host-only SMA reference for normalized * gain + shift, using existing r0 bytes.
# Normalization prepares a representative input, not a full-AdaIN parity claim.
[CmdletBinding()]
param(
    [string] $InputDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\candidates\c64\gen'),
    [string] $WeightDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\emit\r0'),
    [string] $OutputDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\hexagon-emission\affine\reference-sma')
)
$ErrorActionPreference='Stop'
$manifest=Get-Content (Join-Path $WeightDirectory 'r0_static.json') -Raw | ConvertFrom-Json
$raw=[IO.File]::ReadAllBytes((Join-Path $WeightDirectory 'r0_static.bin'))
if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)) -ne $manifest.Sha256){throw 'Weight manifest mismatch'}
$xb=[IO.File]::ReadAllBytes((Join-Path $InputDirectory 'in_z.f32'))
$mb=[IO.File]::ReadAllBytes((Join-Path $InputDirectory 'in_mask1.f32'))
if($xb.Length -ne 3932672 -or $mb.Length -ne 30724 -or $manifest.Channels -ne 128){throw 'Unexpected tensor geometry'}
$x=[single[]]::new($xb.Length/4); [Buffer]::BlockCopy($xb,0,$x,0,$xb.Length)
$mask=[single[]]::new($mb.Length/4); [Buffer]::BlockCopy($mb,0,$mask,0,$mb.Length)
$normalized=[single[]]::new($x.Length); $expected=[single[]]::new($x.Length)
[double]$count=0
foreach($v in $mask){if($v -ne 0 -and $v -ne 1){throw 'Mask must be binary'}; $count+=$v}
if($count -le 0){throw 'Empty normalization domain'}
for($channel=0;$channel -lt 128;$channel++) {
    $start=$channel*7681; [double]$sum=0
    for($sample=0;$sample -lt 7681;$sample++) {
        $value=$x[$start+$sample]; if(-not [single]::IsFinite($value)){throw 'Non-finite input'}
        $sum += [double]$value*$mask[$sample]
    }
    $mean=$sum/$count; [double]$squares=0
    for($sample=0;$sample -lt 7681;$sample++) {
        $delta=([double]$x[$start+$sample]-$mean)*$mask[$sample]; $squares+=$delta*$delta
    }
    $inverse=1/[Math]::Sqrt($squares/$count+1e-5)
    [single]$gain=[BitConverter]::ToSingle($raw,$manifest.Values.'adain1.0.gain'.Offset+4*$channel)
    [single]$shift=[BitConverter]::ToSingle($raw,$manifest.Values.'adain1.0.shift'.Offset+4*$channel)
    for($sample=0;$sample -lt 7681;$sample++) {
        $index=$start+$sample
        $normalized[$index]=[single](([double]$x[$index]-$mean)*$inverse)
        # Explicit binary32 rounding after multiplication and again after addition.
        [single]$product=[single]([double]$normalized[$index]*[double]$gain)
        $expected[$index]=[single]([double]$product+[double]$shift)
        if(-not [single]::IsFinite($expected[$index])){throw 'Non-finite reference'}
    }
}
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$files=[ordered]@{}
foreach($pair in @(@('normalized.f32',$normalized),@('expected.f32',$expected))) {
    $bytes=[byte[]]::new($xb.Length); [Buffer]::BlockCopy($pair[1],0,$bytes,0,$bytes.Length)
    $path=Join-Path $OutputDirectory $pair[0]
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if([IO.File]::Exists($path) -and (Get-FileHash $path).Hash -ne $sha){throw 'Output exists with different bytes; choose a new directory'}
    [IO.File]::WriteAllBytes($path,$bytes)
    $files[$pair[0]]=[ordered]@{Bytes=$bytes.Length;SHA256=$sha}
}
$receipt=[ordered]@{Engine='PowerShell/SMA';Version=$PSVersionTable.PSVersion.ToString();WeightSHA256=$manifest.Sha256;InputSHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($xb));Frames=7681;Channels=128;Values=$expected.Length;Files=$files}
$receipt | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDirectory 'reference.json')
$receipt | ConvertTo-Json -Depth 6
