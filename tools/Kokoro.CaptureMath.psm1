#requires -Version 7.4
# Shared capture reading and statistics for the build-time tools that consume stock PyTorch captures
# (capture.json + float32 tensor files, layout [channel][frame] for activations). Reads are verified
# against the recorded SHA-256 once per file and cached for the session. Statistics run in .NET's
# compiled routines (Enumerable.Min/Max over float[], System.Numerics.Vector<float> dot products) so
# PowerShell iterates per vector chunk, not per element.

$script:TensorCache = @{}
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1')

function Read-KokoroCapture {
    # Loads and checks a capture directory: the stock source commit and verified checkpoint tensors.
    param([Parameter(Mandatory)][string] $Directory)
    $root = (Resolve-Path -LiteralPath $Directory).Path
    $json = Get-Content -LiteralPath (Join-Path $root 'capture.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($json.sourceCommit -cne 'dfb907a02bba8152ca444717ca5d78747ccb4bec' -or $json.verifiedCheckpointTensors -le 0) { throw "Verified stock capture required: $root" }
    @{ Root = $root; Json = $json }
}

function Read-KokoroCaptureTensor {
    # Float32 values of one captured tensor; integrity-checked on first read, then served from cache.
    param([Parameter(Mandatory)][hashtable] $Capture, [Parameter(Mandatory)][string] $Name)
    $key = $Capture.Root + '|' + $Name
    if ($script:TensorCache.ContainsKey($key)) { return , $script:TensorCache[$key] }
    $e = $Capture.Json.tensors[$Name]
    if (-not $e -or $e.file -notmatch '^[a-zA-Z0-9_.]+\.f32$' -or $e.bytes -le 0 -or $e.bytes % 4) { throw "Bad capture tensor $Name" }
    $path = Join-Path $Capture.Root $e.file
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ne $e.bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $e.sha256) { throw "Capture tensor integrity: $Name" }
    $v = [float[]]::new($bytes.Length / 4); [Buffer]::BlockCopy($bytes, 0, $v, 0, $bytes.Length)
    $lo = [Linq.Enumerable]::Min($v); $hi = [Linq.Enumerable]::Max($v)
    if (-not [float]::IsFinite($lo) -or -not [float]::IsFinite($hi)) { throw "Nonfinite value in $Name" }
    $script:TensorCache[$key] = $v
    , $v
}

function Get-KokoroAbsMax {
    param([Parameter(Mandatory)][float[]] $Values)
    [math]::Max([math]::Abs([double][Linq.Enumerable]::Max($Values)), [math]::Abs([double][Linq.Enumerable]::Min($Values)))
}

function Get-KokoroChannelStats {
    # Per channel of a [channel][frame] tensor: AbsMax, Mean and population Variance (double).
    param([Parameter(Mandatory)][float[]] $Values, [Parameter(Mandatory)][int] $Channels)
    if ($Values.Length % $Channels) { throw 'Tensor length is not a multiple of the channel count.' }
    $frames = $Values.Length / $Channels
    $absMax = [double[]]::new($Channels); $sum = [double[]]::new($Channels); $sq = [double[]]::new($Channels)
    (Get-ChannelStatsKernel).Invoke($Values, $Channels, $absMax, $sum, $sq)
    $mean = [double[]]::new($Channels); $var = [double[]]::new($Channels)
    for ($c = 0; $c -lt $Channels; $c++) { $mean[$c] = $sum[$c] / $frames; $var[$c] = [math]::Max($sq[$c] / $frames - $mean[$c] * $mean[$c], 0.0) }
    [pscustomobject]@{ AbsMax = $absMax; Mean = $mean; Variance = $var; Frames = $frames }
}

Export-ModuleMember -Function Read-KokoroCapture, Read-KokoroCaptureTensor, Get-KokoroAbsMax, Get-KokoroChannelStats
