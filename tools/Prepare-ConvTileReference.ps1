#requires -Version 7.4
# SMA reference, not a PyTorch parity claim. Snake is evaluated on the host to
# supply representative convolution inputs; only convolution executes on DSP.
[CmdletBinding()]
param(
    [string]$AffineDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\hexagon-emission\affine\reference-sma'),
    [string]$WeightDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\emit\r0'),
    [string]$OutputDirectory=(Join-Path $PSScriptRoot '..\..\Build\Kokoro-QNN\hexagon-emission\conv-tile\reference')
)
$ErrorActionPreference='Stop'
$manifest=Get-Content (Join-Path $WeightDirectory 'r0_static.json') -Raw | ConvertFrom-Json
$wb=[IO.File]::ReadAllBytes((Join-Path $WeightDirectory 'r0_static.bin'))
$ab=[IO.File]::ReadAllBytes((Join-Path $AffineDirectory 'expected.f32'))
$hash={param([byte[]]$b) [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b))}
if((& $hash $wb) -ne '997CF6049BBDF8BD987CC757CE04D5EEF73C167315C4E426FEF275AB4A0F3B05' -or
    (& $hash $ab) -ne 'FB44F04A5776DC460C67EE74AB9D25C5063D606663A5A06F511EDFC9CEF85C8F' -or
    $wb.Length -ne 1195008 -or $ab.Length -ne 3932672 -or $manifest.Sha256 -ne (& $hash $wb)) { throw 'Reference input pin mismatch' }
foreach($entry in @(@('convs1.0.weight',0),@('convs1.0.bias',196608),@('alpha1.0',1188864),@('alpha1.0.inv',1189376))) {
    if($manifest.Values.($entry[0]).Offset -ne $entry[1]) { throw 'Unexpected weight manifest offsets' }
}
$w=[single[]]::new($wb.Length/4); [Buffer]::BlockCopy($wb,0,$w,0,$wb.Length)
$a=[single[]]::new($ab.Length/4); [Buffer]::BlockCopy($ab,0,$a,0,$ab.Length)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$write={param([string]$name,[single[]]$values)
    $b=[byte[]]::new(4*$values.Length); [Buffer]::BlockCopy($values,0,$b,0,$b.Length)
    $p=Join-Path $OutputDirectory $name; $sha=& $hash $b
    if([IO.File]::Exists($p) -and (Get-FileHash $p).Hash -ne $sha){throw 'Choose a fresh reference directory'}
    [IO.File]::WriteAllBytes($p,$b)
    [ordered]@{File=$name;Bytes=$b.Length;SHA256=$sha}
}
$cases=[Collections.Generic.List[object]]::new()
foreach($start in 0,4096,7616) {
    $x=[single[]]::new(128*67); $y=[single[]]::new(128*65)
    for($ic=0;$ic -lt 128;$ic++) {
        $alpha=$w[297216+$ic]; $inverse=$w[297344+$ic]
        for($t=0;$t -lt 67;$t++) {
            $source=$start+$t-1
            if($source -lt 0 -or $source -ge 7681){continue}
            $v=$a[$ic*7681+$source]
            [single]$angle=[single]([double]$alpha*$v)
            [single]$sine=[MathF]::Sin($angle)
            [single]$square=[single]([double]$sine*$sine)
            [single]$term=[single]([double]$inverse*$square)
            $x[$ic*67+$t]=[single]([double]$v+$term)
            if(-not [single]::IsFinite($x[$ic*67+$t])){throw 'Non-finite Snake reference'}
        }
    }
    # Tap-major/input-channel order matches the specified scalar DSP contract.
    # A double-precision sum also checks that rounding error remains bounded.
    [double]$maxDoubleError=0
    for($oc=0;$oc -lt 128;$oc++) {
        for($t=0;$t -lt 65;$t++) {
            [single]$sum=0; [double]$doubleSum=0
            for($k=0;$k -lt 3;$k++) {
                for($ic=0;$ic -lt 128;$ic++) {
                    $v=$x[$ic*67+$t+$k]; $weight=$w[($k*128+$ic)*128+$oc]
                    [single]$p=[single]([double]$v*$weight)
                    $sum=[single]([double]$sum+$p); $doubleSum+=[double]$v*$weight
                }
            }
            $bias=$w[49152+$oc]; $y[$oc*65+$t]=[single]([double]$sum+$bias)
            if(-not [single]::IsFinite($y[$oc*65+$t])){throw 'Non-finite convolution reference'}
            $maxDoubleError=[Math]::Max($maxDoubleError,[Math]::Abs([double]$y[$oc*65+$t]-($doubleSum+$bias)))
        }
    }
    $cases.Add([ordered]@{Start=$start;Input=(& $write "input-$start.f32" $x);Expected=(& $write "expected-$start.f32" $y);MaxDoubleError=$maxDoubleError})
}
$receipt=[ordered]@{Engine='PowerShell/SMA';Frames=65;Channels=128;Halo=1;WeightsSHA256=(& $hash $wb);AffineSHA256=(& $hash $ab);Cases=$cases.ToArray()}
$json=$receipt | ConvertTo-Json -Depth 8
$path=Join-Path $OutputDirectory 'reference.json'
if([IO.File]::Exists($path) -and [IO.File]::ReadAllText($path) -cne $json){throw 'Choose a fresh reference directory'}
[IO.File]::WriteAllText($path,$json)
$cases | ForEach-Object { [pscustomobject]@{Start=$_.Start;Values=8320;MaxDoubleError=$_.MaxDoubleError;ExpectedSHA256=$_.Expected.SHA256} }
