#requires -Version 7.4
# Build the static tensors for one AdaINResBlock1 straight from the checkpoint:
# weight_norm fused, conv weights transposed to QNN's [1,K,Cin,Cout], and AdaIN's
# gamma/beta evaluated for a fixed style so the graph carries per-channel constants.
[CmdletBinding()]
param(
    [string] $Checkpoint = 'C:\models\Kokoro-82M\kokoro-v1_0.pth',
    [int]    $Block      = 3,
    [string] $StyleFile  = 'C:\Dev\Build\Kokoro-QNN\candidates\c64\gen\in_style.f32',
    [string] $OutDir     = 'C:\Dev\Build\Kokoro-QNN\emit\r0',
    [string] $ReaderPath = 'C:\Dev\Kokoro-QNN\src\runspace\Torch.Checkpoint.psm1'
)
$ErrorActionPreference = 'Stop'
[void](New-Item -ItemType Directory -Force $OutDir)

$reader = [scriptblock]::Create([IO.File]::ReadAllText($ReaderPath)).InvokeReturnAsIs()
$ck = & $reader.Read $Checkpoint
$prefix = "decoder.module.generator.resblocks.$Block."

[float[]]$style = [float[]]::new(128)
[byte[]]$sb = [IO.File]::ReadAllBytes($StyleFile)
if ($sb.Length -ne 512) { throw "style expected 512 bytes, got $($sb.Length)" }
for ([int]$i = 0; $i -lt 128; $i++) { $style[$i] = [BitConverter]::ToSingle($sb, $i * 4) }

$asFloats = {
    param([string]$Name)
    [byte[]]$b = & $reader.Bytes $ck ($prefix + $Name)
    [float[]]$f = [float[]]::new($b.Length / 4)
    [Buffer]::BlockCopy($b, 0, $f, 0, $b.Length)
    , $f
}

$parts = [Collections.Specialized.OrderedDictionary]::new()
$blob = [IO.MemoryStream]::new()
$add = {
    param([string]$Name, [float[]]$Values, [int[]]$Shape)
    [byte[]]$bytes = [byte[]]::new($Values.Length * 4)
    [Buffer]::BlockCopy($Values, 0, $bytes, 0, $bytes.Length)
    $parts[$Name] = [pscustomobject]@{ Offset = [int]$blob.Position; Bytes = $bytes.Length; Shape = $Shape }
    $blob.Write($bytes, 0, $bytes.Length)
}

[int]$Cch = 128; [int]$Kw = 3
foreach ($set in 'convs1', 'convs2') {
    for ([int]$j = 0; $j -lt 3; $j++) {
        [float[]]$v = & $asFloats "$set.$j.weight_v"          # [Cout, Cin, K]
        [float[]]$g = & $asFloats "$set.$j.weight_g"          # [Cout,1,1]
        [float[]]$bias = & $asFloats "$set.$j.bias"
        if ($v.Length -ne $Cch * $Cch * $Kw) { throw "$set.$j.weight_v length $($v.Length)" }
        # fuse weight_norm over dim 0, then transpose [Cout,Cin,K] -> [1,K,Cin,Cout]
        [float[]]$w = [float[]]::new($Cch * $Cch * $Kw)
        for ([int]$oc = 0; $oc -lt $Cch; $oc++) {
            [int]$base = $oc * $Cch * $Kw
            [double]$ss = 0
            for ([int]$n = 0; $n -lt $Cch * $Kw; $n++) { [double]$x = $v[$base + $n]; $ss += $x * $x }
            [double]$scale = $g[$oc] / [Math]::Sqrt($ss)
            for ([int]$ic = 0; $ic -lt $Cch; $ic++) {
                for ([int]$kt = 0; $kt -lt $Kw; $kt++) {
                    $w[(($kt * $Cch) + $ic) * $Cch + $oc] = [float]($v[$base + $ic * $Kw + $kt] * $scale)
                }
            }
        }
        & $add "$set.$j.weight" $w ([int[]]@(1, $Kw, $Cch, $Cch))
        & $add "$set.$j.bias"   $bias ([int[]]@($Cch))
    }
}

foreach ($set in 'adain1', 'adain2') {
    for ([int]$j = 0; $j -lt 3; $j++) {
        [float[]]$fw = & $asFloats "$set.$j.fc.weight"        # [256,128]
        [float[]]$fb = & $asFloats "$set.$j.fc.bias"          # [256]
        [float[]]$h = [float[]]::new(256)
        for ([int]$o = 0; $o -lt 256; $o++) {
            [double]$acc = $fb[$o]
            [int]$row = $o * 128
            for ([int]$i = 0; $i -lt 128; $i++) { $acc += [double]$fw[$row + $i] * $style[$i] }
            $h[$o] = [float]$acc
        }
        # (1 + gamma) and beta, per channel, shaped for broadcast over [1,1,T,C]
        [float[]]$gain = [float[]]::new($Cch); [float[]]$shift = [float[]]::new($Cch)
        for ([int]$ch = 0; $ch -lt $Cch; $ch++) { $gain[$ch] = [float](1.0 + $h[$ch]); $shift[$ch] = $h[$Cch + $ch] }
        & $add "$set.$j.gain"  $gain  ([int[]]@(1, 1, 1, $Cch))
        & $add "$set.$j.shift" $shift ([int[]]@(1, 1, 1, $Cch))
    }
}

foreach ($set in 'alpha1', 'alpha2') {
    for ([int]$j = 0; $j -lt 3; $j++) {
        [float[]]$a = & $asFloats "$set.$j"                   # [1,C,1]
        [float[]]$inv = [float[]]::new($Cch)
        for ([int]$ch = 0; $ch -lt $Cch; $ch++) { $inv[$ch] = [float](1.0 / $a[$ch]) }
        & $add "$set.$j"     $a   ([int[]]@(1, 1, 1, $Cch))
        & $add "$set.$j.inv" $inv ([int[]]@(1, 1, 1, $Cch))
    }
}

[byte[]]$all = $blob.ToArray(); $blob.Dispose()
$binPath = Join-Path $OutDir 'r0_static.bin'
[IO.File]::WriteAllBytes($binPath, $all)
$sha = (Get-FileHash $binPath -Algorithm SHA256).Hash
$manifest = [pscustomobject]@{
    Block = "resblocks.$Block"; Source = $Checkpoint; Style = $StyleFile
    Channels = $Cch; Kernel = $Kw; Dilations = @(1, 3, 5); Eps = 1e-5
    Bytes = $all.Length; Sha256 = $sha
    Values = $parts
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutDir 'r0_static.json')
'{0} tensors, {1:N0} bytes, sha {2}' -f $parts.Count, $all.Length, $sha.Substring(0, 16)
$parts.GetEnumerator() | Select-Object -First 6 | ForEach-Object { '  {0,-22} off={1,-8} bytes={2,-8} shape=[{3}]' -f $_.Key, $_.Value.Offset, $_.Value.Bytes, ($_.Value.Shape -join ',') }
