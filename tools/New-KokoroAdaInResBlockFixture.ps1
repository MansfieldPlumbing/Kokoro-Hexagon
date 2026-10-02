#requires -Version 7.4
# One bounded stock generator block, prepared and evaluated on the PC only.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,
    [string]$CheckpointPath='C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string]$VoicePath='C:\models\Kokoro-82M\voices\af_heart.pt')
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $out.StartsWith((Join-Path $repo 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($out)){
    throw 'Use a new output directory inside repository build.'
}
$weights=& (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') -CheckpointPath $CheckpointPath -SkipFiniteScan
[float[]]$voice=& (Join-Path $repo 'src/models/Read-KokoroVoiceRow.ps1') -VoicePath $VoicePath -PhonemeCount 7
$parameters=@{}
foreach($name in $weights.Parameters.Keys){
    if($name.StartsWith('resblocks.3.',[StringComparison]::Ordinal)){$parameters[$name.Substring(12)]=$weights.Parameters[$name]}
}
if($parameters.Count -ne 36){throw 'Unexpected generator block parameter count'}
[void][IO.Directory]::CreateDirectory($out)
function Write-Floats([string]$Name,[float[]]$Values){
    $bytes=[byte[]]::new(4*$Values.Length);[Buffer]::BlockCopy($Values,0,$bytes,0,$bytes.Length)
    [IO.File]::WriteAllBytes((Join-Path $out $Name),$bytes)
}
[float[]]$x=[float[]]::new(8192)
for($c=0;$c -lt 128;$c++){for($t=0;$t -lt 64;$t++){$x[$c*64+$t]=[float](0.1*[Math]::Sin(($t+1)*0.19+$c*0.07))}}
$folded=@{}
for($pass=0;$pass -lt 3;$pass++){foreach($side in 1,2){
    $prefix="convs$side.$pass"
    [float[]]$oik=& (Join-Path $repo 'src/models/ConvertTo-KokoroWeightNormConv1dWeights.ps1') `
        -InputChannels 128 -OutputChannels 128 -KernelSize 3 -WeightV $parameters["$prefix.weight_v"] -WeightG $parameters["$prefix.weight_g"]
    $kio=[float[]]::new(49152)
    for($o=0;$o -lt 128;$o++){for($i=0;$i -lt 128;$i++){for($k=0;$k -lt 3;$k++){$kio[($k*128+$i)*128+$o]=$oik[($o*128+$i)*3+$k]}}}
    $folded[$prefix]=$kio
}}
$cases=[Collections.Generic.List[object]]::new()
foreach($name in 'stock-block','mutated-style-block'){
    $style=[float[]]::new(128);[Array]::Copy($voice,0,$style,0,128)
    if($name -eq 'mutated-style-block'){$style[3]+=[float]0.01;$style[41]-=[float]0.02}
    $packed=[float[]]::new(6*49792)
    for($pass=0;$pass -lt 3;$pass++){foreach($side in 1,2){
        $stage=$pass*2+$side-1;$base=$stage*49792
        $fc="adain$side.$pass.fc"
        $affine=& (Join-Path $repo 'src/models/ConvertTo-KokoroAdaInStyle.ps1') `
            -Style $style -Weights $parameters["$fc.weight"] -Bias $parameters["$fc.bias"] -Channels 128
        [Array]::Copy($affine.Gain,0,$packed,$base,128);[Array]::Copy($affine.Shift,0,$packed,($base+128),128)
        [float[]]$alpha=$parameters["alpha$side.$pass"]
        for($c=0;$c -lt 128;$c++){
            if(-not [float]::IsFinite($alpha[$c]) -or [Math]::Abs($alpha[$c]) -lt 0.001 -or [Math]::Abs($alpha[$c]) -gt 2){throw 'Snake alpha outside tested domain'}
            $packed[$base+256+$c]=$alpha[$c];$packed[$base+384+$c]=[float](1.0/$alpha[$c])
        }
        [Array]::Copy($folded["convs$side.$pass"],0,$packed,($base+512),49152)
        [Array]::Copy($parameters["convs$side.$pass.bias"],0,$packed,($base+49664),128)
    }}
    Write-Floats "$name.input.bin" $x;Write-Floats "$name.control.bin" $packed
    [float[]]$reference=& (Join-Path $repo 'src/models/Invoke-KokoroAdaInResBlock1.ps1') `
        -InputTensor $x -Style $style -Parameters $parameters -Frames 64 -Channels 128 -KernelSize 3 -Dilations @(1,3,5)
    Write-Floats "$name.reference.bin" $reference
    $cases.Add([ordered]@{Name=$name;ExpectedRc=0;Input="$name.input.bin";Control="$name.control.bin";Output="$name.output.bin";Frames=64;InputBytes=32768})
    Write-Information "Prepared $name stock oracle." -InformationAction Continue
}
$files=@(Get-ChildItem -LiteralPath $out -File|ForEach-Object{[ordered]@{Name=$_.Name;Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$manifest=[ordered]@{Schema=1;Role='direct_adain_resblock_diagnostic';Frames=64;Channels=128;
    SourceRevision='dfb907a02bba8152ca444717ca5d78747ccb4bec';CheckpointSHA256=$weights.CheckpointSha256;
    VoiceSHA256=(Get-FileHash -LiteralPath $VoicePath).Hash;ControlSource='decoder.module.generator.resblocks.3';
    WeightLayout='six stages of gain,shift,alpha,inverseAlpha,foldedKIO,bias';Cases=$cases.ToArray();Files=$files}
[IO.File]::WriteAllText((Join-Path $out 'fixture.json'),($manifest|ConvertTo-Json -Depth 6))
[pscustomobject]@{Directory=$out;Cases=$cases.Count;WeightBytes=1195008;ScratchBytes=103424}
