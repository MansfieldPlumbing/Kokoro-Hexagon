param()

# Layout-only implementation of the public DSPQueue v1/v2 arena header.
# Source: qualcomm/fastrpc d247519650fe5cb16de6c78edaa95bcc4be25073
# inc/dspqueue_shared.h:11-79; src/dspqueue/dspqueue_cpu.c:131-133,541-589.
# Message-only packet: inc/dspqueue.h:28-33;
# src/dspqueue/dspqueue_cpu.c:1404-1437,1500-1529.
# This does not allocate shared memory, import a queue, or establish signaling.

$align256 = {
    param([long]$Size)
    if ($Size -lt 0 -or $Size -gt [int]::MaxValue - 255) {
        throw 'DSPQueue size is outside the supported range.'
    }
    [int](($Size + 255) -band (-bnot 255))
}.GetNewClosure()

$newArena = {
    param(
        [long]$RequestBytes = 65536,
        [long]$ResponseBytes = 16384,
        [uint32]$QueueCount = 0,
        [ValidateSet(1, 2)][int]$Version = 1,
        [switch]$WaitCounts,
        [switch]$DriverSignaling
    )

    if (-not [BitConverter]::IsLittleEndian) {
        throw 'DSPQueue header emission requires a little-endian host.'
    }
    if ($RequestBytes -lt 8 -or $RequestBytes -gt 16777216 -or
        $ResponseBytes -lt 8 -or $ResponseBytes -gt 16777216) {
        throw 'DSPQueue packet queue size must be between 8 bytes and 16 MiB.'
    }
    if ($Version -eq 1 -and ($WaitCounts -or $DriverSignaling)) {
        throw 'DSPQueue v1 cannot declare v2 flags.'
    }
    if ($Version -eq 2 -and -not $WaitCounts) {
        throw 'DSPQueue v2 requires wait counts for this source contract.'
    }
    if ($DriverSignaling -and -not $WaitCounts) {
        throw 'DSPQueue driver signaling requires wait counts.'
    }

    $requestLength = [int]$RequestBytes
    $responseLength = [int]$ResponseBytes
    $requestOffset = & $align256 48
    $requestReadState = $requestOffset + (& $align256 $requestLength)
    $requestWriteState = $requestReadState + (& $align256 12)
    $responseOffset = $requestWriteState + (& $align256 12)
    $responseReadState = $responseOffset + (& $align256 $responseLength)
    $responseWriteState = $responseReadState + (& $align256 12)
    $totalBytes = $responseWriteState + (& $align256 12)
    if ($totalBytes -gt [int]::MaxValue) { throw 'DSPQueue arena exceeds the supported array size.' }

    [byte[]]$bytes = [byte[]]::new($totalBytes)
    $put32 = {
        param([int]$Offset, [uint32]$Value)
        [BitConverter]::GetBytes($Value).CopyTo($bytes, $Offset)
    }.GetNewClosure()
    $flags = [uint32]0
    if ($WaitCounts) { $flags = $flags -bor [uint32]1 }
    if ($DriverSignaling) { $flags = $flags -bor [uint32]2 }

    & $put32 0 ([uint32]$Version)
    & $put32 8 $flags
    & $put32 12 ([uint32]$requestOffset)
    & $put32 16 ([uint32]$requestLength)
    & $put32 20 ([uint32]$requestReadState)
    & $put32 24 ([uint32]$requestWriteState)
    & $put32 28 ([uint32]$responseOffset)
    & $put32 32 ([uint32]$responseLength)
    & $put32 36 ([uint32]$responseReadState)
    & $put32 40 ([uint32]$responseWriteState)
    & $put32 44 $QueueCount

    [pscustomobject]@{
        Bytes = $bytes
        TotalBytes = $totalBytes
        RequestOffset = $requestOffset
        RequestReadStateOffset = $requestReadState
        RequestWriteStateOffset = $requestWriteState
        ResponseOffset = $responseOffset
        ResponseReadStateOffset = $responseReadState
        ResponseWriteStateOffset = $responseWriteState
        Version = $Version
        Flags = $flags
    }
}.GetNewClosure()

# Message-only packet bytes. Buffer descriptors and ring publication are
# deliberately outside this layout-only contract.
$newMessagePacket = {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Message,
        [ValidateRange(0, 255)][int]$Sequence = 0,
        [ValidateRange(8, 16777216)][int]$QueueBytes = 65536
    )
    if (-not [BitConverter]::IsLittleEndian) {
        throw 'DSPQueue packet emission requires a little-endian host.'
    }
    if ($Message.Length -gt 65536) {
        throw 'DSPQueue message exceeds the public maximum of 65536 bytes.'
    }
    $packetLength = 8 + $Message.Length
    $alignedLength = ($packetLength + 7) -band (-bnot 7)
    if ($alignedLength -gt $QueueBytes - 8) {
        throw 'DSPQueue packet does not fit the ring with its required spare header.'
    }
    [byte[]]$bytes = [byte[]]::new($alignedLength)
    [BitConverter]::GetBytes([uint32]$packetLength).CopyTo($bytes, 0)
    $flags = [uint16]0x10
    if ($Message.Length) { $flags = $flags -bor [uint16]0x01 }
    [BitConverter]::GetBytes($flags).CopyTo($bytes, 4)
    $bytes[6] = 0 # buffer descriptor count
    $bytes[7] = [byte]$Sequence
    if ($Message.Length) { [Array]::Copy($Message, 0, $bytes, 8, $Message.Length) }
    [pscustomobject]@{
        Bytes = $bytes
        PacketLength = $packetLength
        AlignedLength = $alignedLength
        Flags = $flags
        Sequence = $Sequence
    }
}.GetNewClosure()

[pscustomobject]@{
    PSTypeName = 'Kokoro.DspQueue.Layout'
    NewArena = $newArena
    NewMessagePacket = $newMessagePacket
}
