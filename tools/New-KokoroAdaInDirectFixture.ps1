#requires -Version 7.4
# PC-only bounded oracle fixtures for the complete emitted AdaIN operation.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,
    [string]$CheckpointPath='C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [string]$VoicePath='C:\models\Kokoro-82M\voices\af_heart.pt')
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $out.StartsWith((Join-Path $repo 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
    [IO.Directory]::Exists($out)){throw 'Use a new directory under repository build.'}
$weights=& (Join-Path $repo 'src/models/Read-KokoroGeneratorWeights.ps1') -CheckpointPath $CheckpointPath -SkipFiniteScan
[float[]]$voice=& (Join-Path $repo 'src/models/Read-KokoroVoiceRow.ps1') -VoicePath $VoicePath -PhonemeCount 7
[float[]]$style=[float[]]::new(128);[Array]::Copy($voice,0,$style,0,128)
$prefix='resblocks.3.adain1.0.fc'
$affine=& (Join-Path $repo 'src/models/ConvertTo-KokoroAdaInStyle.ps1') -Style $style `
    -Weights $weights.Parameters["$prefix.weight"] -Bias $weights.Parameters["$prefix.bias"] -Channels 128
[void][IO.Directory]::CreateDirectory($out)
function Write-Floats([string]$Name,[float[]]$Values){
    $bytes=[byte[]]::new(4*$Values.Length);[Buffer]::BlockCopy($Values,0,$bytes,0,$bytes.Length)
    [IO.File]::WriteAllBytes((Join-Path $out $Name),$bytes)
}
$cases=[Collections.Generic.List[object]]::new()
foreach($name in 'varying','shifted','constant','nearconstant','alternating','changed-control','nan-input','tail-nan-input','large-input','nan-control','tail-nan-control','short-input','wrong-shape'){
    [float[]]$x=[float[]]::new(128*64)
    for($c=0;$c -lt 128;$c++){
        for($t=0;$t -lt 64;$t++){
            $value=[Math]::Sin(($t+1)*0.19+$c*0.07)+(($t%7)-3)*0.03
            switch($name){
                'shifted' {$value+=7}
                'constant' {$value=2.5}
                'nearconstant' {$value=0.5+(($t%5)-2)*0.0001}
                'alternating' {$value=if($t%2){1024}else{-1024}}
            }
            $x[$c*64+$t]=[float]$value
        }
    }
    [float[]]$gain=$affine.Gain.Clone();[float[]]$shift=$affine.Shift.Clone()
    if($name -eq 'changed-control'){
        $gain[0]+=[float]0.125;$shift[3]-=[float]0.125
    }
    [int]$rc=0
    if($name -eq 'nan-input'){$x[0]=[float]::NaN;$rc=33}
    if($name -eq 'tail-nan-input'){$x[$x.Length-1]=[float]::NaN;$rc=33}
    if($name -eq 'large-input'){$x[0]=2048;$rc=33}
    if($name -eq 'nan-control'){$gain[0]=[float]::NaN;$rc=33}
    if($name -eq 'tail-nan-control'){$shift[127]=[float]::NaN;$rc=33}
    if($name -in 'short-input','wrong-shape'){$rc=14}
    [float[]]$control=[float[]]::new(256)
    [Array]::Copy($gain,0,$control,0,128);[Array]::Copy($shift,0,$control,128,128)
    Write-Floats "$name.input.bin" $x;Write-Floats "$name.control.bin" $control
    if($rc -eq 0){
        [float[]]$reference=& (Join-Path $repo 'src/models/ConvertTo-KokoroAdaIn.ps1') -InputTensor $x `
            -Frames 64 -Channels 128 -Gain $gain -Shift $shift
        Write-Floats "$name.reference.bin" $reference
    }
    $cases.Add([ordered]@{Name=$name;ExpectedRc=$rc;Input="$name.input.bin";Control="$name.control.bin";
        Output="$name.output.bin";Frames=$(if($name -eq 'wrong-shape'){63}else{64});
        InputBytes=$(if($name -eq 'short-input'){4}else{32768})})
}
$files=@(Get-ChildItem -LiteralPath $out -File | ForEach-Object {
    [ordered]@{Name=$_.Name;Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
$manifest=[ordered]@{Schema=1;Role='direct_adain_diagnostic';Frames=64;Channels=128;
    SourceRevision='dfb907a02bba8152ca444717ca5d78747ccb4bec';CheckpointSHA256=$weights.CheckpointSha256;
    VoiceSHA256=(Get-FileHash -LiteralPath $VoicePath).Hash;
    ControlSource="decoder.module.generator.$prefix";Cases=$cases.ToArray();Files=$files}
[IO.File]::WriteAllText((Join-Path $out 'fixture.json'),($manifest|ConvertTo-Json -Depth 6))
[pscustomobject]@{Directory=$out;Cases=$cases.Count;NumericalCases=6}
