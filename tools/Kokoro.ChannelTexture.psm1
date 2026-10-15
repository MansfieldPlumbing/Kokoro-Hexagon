# Channel textures of a channels x frames tensor (e.g. stored decoder output, 512 x 2 per 80 Hz frame).
# Measures how much a neighbour difference shrinks the values (between sorted channels, and frame to frame)
# and optionally renders three panels: raw channel order, neighbour-sorted, neighbour-channel difference.

function Measure-KokoroChannelTexture {
    <#
    .SYNOPSIS
    Measures channel and time redundancy of a float32 channels x frames tensor and optionally renders it as textures.
    .EXAMPLE
    Import-Module ./tools/Kokoro.ChannelTexture.psm1
    Measure-KokoroChannelTexture -Path build/node-capture-20261014/dog.gen.input_x.bin -Channels 512 -ImagePath build/dog-textures.png
    #>
    [CmdletBinding()]
    param(
        # Raw little-endian float32, channel-major (C order, batch dimension 1).
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateRange(1, 4096)][int] $Channels,
        # PNG of the three panels; omitted = numbers only.
        [string] $ImagePath,
        [ValidateRange(1, 16)][int] $PixelWidth = 4,
        [ValidateRange(1, 16)][int] $PixelHeight = 2
    )
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
    if ($bytes.Length % (4 * $Channels)) { throw "$Path holds $($bytes.Length) bytes, not a whole number of $Channels-channel float32 frames" }
    $frameCount = $bytes.Length / 4 / $Channels
    $flat = [float[]]::new($Channels * $frameCount); [Buffer]::BlockCopy($bytes, 0, $flat, 0, $bytes.Length)
    $rows = [double[][]]::new($Channels)
    for ($ch = 0; $ch -lt $Channels; $ch++) {
        $row = [double[]]::new($frameCount)
        for ($i = 0; $i -lt $frameCount; $i++) { $row[$i] = $flat[$ch * $frameCount + $i] }
        $rows[$ch] = $row
    }

    # Greedy neighbour order: each next channel is the unused one nearest (squared difference) to the current one.
    $used = [bool[]]::new($Channels); $order = [int[]]::new($Channels); $current = 0; $used[0] = $true
    for ($k = 1; $k -lt $Channels; $k++) {
        $best = -1; $bestDistance = [double]::MaxValue; $a = $rows[$current]
        for ($j = 0; $j -lt $Channels; $j++) {
            if ($used[$j]) { continue }
            $b = $rows[$j]; $distance = 0.0
            for ($i = 0; $i -lt $frameCount; $i++) { $e = $a[$i] - $b[$i]; $distance += $e * $e }
            if ($distance -lt $bestDistance) { $bestDistance = $distance; $best = $j }
        }
        $used[$best] = $true; $order[$k] = $best; $current = $best
    }
    $sorted = [double[][]]::new($Channels)
    for ($k = 0; $k -lt $Channels; $k++) { $sorted[$k] = $rows[$order[$k]] }
    $channelDiff = [double[][]]::new($Channels); $channelDiff[0] = $sorted[0]
    for ($k = 1; $k -lt $Channels; $k++) {
        $d = [double[]]::new($frameCount)
        for ($i = 0; $i -lt $frameCount; $i++) { $d[$i] = $sorted[$k][$i] - $sorted[$k - 1][$i] }
        $channelDiff[$k] = $d
    }

    $energy = { param([double[][]] $m, [int] $skipRows, [int] $skipColumns)
        $sum = 0.0; $n = 0
        for ($r = $skipRows; $r -lt $m.Length; $r++) { for ($i = $skipColumns; $i -lt $m[$r].Length; $i++) { $sum += $m[$r][$i] * $m[$r][$i]; $n++ } }
        $sum / $n }
    $timeDiffSum = 0.0; $timeDiffCount = 0
    foreach ($row in $rows) { for ($i = 1; $i -lt $frameCount; $i++) { $e = $row[$i] - $row[$i - 1]; $timeDiffSum += $e * $e; $timeDiffCount++ } }
    $raw = & $energy $rows 0 0
    $neighbour = & $energy $channelDiff 1 0
    $time = $timeDiffSum / $timeDiffCount

    if ($ImagePath) {
        Add-Type -AssemblyName System.Drawing
        $panelWidth = $frameCount * $PixelWidth; $gap = 12
        $bitmap = [Drawing.Bitmap]::new(3 * $panelWidth + 2 * $gap, $Channels * $PixelHeight)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Black)
            $peak = 0.0; foreach ($row in $rows) { foreach ($v in $row) { if ([math]::Abs($v) -gt $peak) { $peak = [math]::Abs($v) } } }
            $scale = [math]::Max($peak * 0.4, 1e-12); $panels = @($rows, $sorted, $channelDiff)
            for ($p = 0; $p -lt 3; $p++) {
                $x0 = $p * ($panelWidth + $gap)
                for ($ch = 0; $ch -lt $Channels; $ch++) {
                    for ($i = 0; $i -lt $frameCount; $i++) {
                        # Red positive, blue negative, white zero.
                        $v = [math]::Max(-1.0, [math]::Min(1.0, $panels[$p][$ch][$i] / $scale))
                        $color = if ($v -ge 0) { [Drawing.Color]::FromArgb(255, 255, [int](255 * (1 - $v)), [int](255 * (1 - $v))) }
                                 else { [Drawing.Color]::FromArgb(255, [int](255 * (1 + $v)), [int](255 * (1 + $v)), 255) }
                        $brush = [Drawing.SolidBrush]::new($color)
                        $graphics.FillRectangle($brush, $x0 + $i * $PixelWidth, $ch * $PixelHeight, $PixelWidth, $PixelHeight)
                        $brush.Dispose()
                    }
                }
            }
            $bitmap.Save($ImagePath, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }

    [pscustomobject]@{
        PSTypeName                = 'Kokoro.ChannelTexture'
        Path                      = $Path
        Channels                  = $Channels
        Frames                    = $frameCount
        RawEnergy                 = $raw
        NeighbourChannelEnergy    = $neighbour
        NeighbourChannelReduction = $raw / $neighbour
        FrameToFrameEnergy        = $time
        FrameToFrameReduction     = $raw / $time
        ChannelOrder              = $order
        ImagePath                 = $ImagePath
    }
}

Export-ModuleMember -Function Measure-KokoroChannelTexture
