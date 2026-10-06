#requires -Version 7.4
$ErrorActionPreference = 'Stop'
$path = [IO.Path]::GetFullPath([IO.Path]::Combine(
    $PSScriptRoot, '..', 'src', 'runspace', 'DspQueue.Layout.psm1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'DspQueue.Layout.psm1 does not parse.' }
$layout = $ast.GetScriptBlock().InvokeReturnAsIs()

$arena = & $layout.NewArena
$expected = [ordered]@{
    TotalBytes = 83200
    RequestOffset = 256
    RequestReadStateOffset = 65792
    RequestWriteStateOffset = 66048
    ResponseOffset = 66304
    ResponseReadStateOffset = 82688
    ResponseWriteStateOffset = 82944
}
foreach ($name in $expected.Keys) {
    if ($arena.$name -ne $expected[$name]) { throw "DSPQueue layout mismatch: $name" }
}

$fields = [ordered]@{
    '0' = 1; '4' = 0; '8' = 0; '12' = 256; '16' = 65536
    '20' = 65792; '24' = 66048; '28' = 66304; '32' = 16384
    '36' = 82688; '40' = 82944; '44' = 0
}
foreach ($offset in $fields.Keys) {
    if ([BitConverter]::ToUInt32($arena.Bytes, [int]$offset) -ne $fields[$offset]) {
        throw "DSPQueue header field mismatch at offset $offset."
    }
}
foreach ($offset in @($arena.RequestReadStateOffset, $arena.RequestWriteStateOffset,
        $arena.ResponseReadStateOffset, $arena.ResponseWriteStateOffset)) {
    if ([BitConverter]::ToUInt32($arena.Bytes, $offset) -ne 0) {
        throw 'DSPQueue state was not zero-initialized.'
    }
}

$v2 = & $layout.NewArena 257 513 7 2 -WaitCounts -DriverSignaling
if ($v2.TotalBytes -ne 2560 -or $v2.Flags -ne 3 -or
    [BitConverter]::ToUInt32($v2.Bytes, 0) -ne 2 -or
    [BitConverter]::ToUInt32($v2.Bytes, 44) -ne 7) {
    throw 'DSPQueue v2 layout or flags are incorrect.'
}

foreach ($test in @(
    { & $layout.NewArena 7 16384 },
    { & $layout.NewArena 16777217 16384 },
    { & $layout.NewArena 65536 16384 0 1 -WaitCounts },
    { & $layout.NewArena 65536 16384 0 2 }
)) {
    $rejected = $false
    try { [void](& $test) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid DSPQueue layout was accepted.' }
}

$packet = & $layout.NewMessagePacket ([byte[]](0x41, 0x42, 0x43)) 255
if ($packet.PacketLength -ne 11 -or $packet.AlignedLength -ne 16 -or
    $packet.Flags -ne 0x11 -or $packet.Bytes.Length -ne 16 -or
    [BitConverter]::ToUInt32($packet.Bytes, 0) -ne 11 -or
    [BitConverter]::ToUInt16($packet.Bytes, 4) -ne 0x11 -or
    $packet.Bytes[6] -ne 0 -or $packet.Bytes[7] -ne 255 -or
    $packet.Bytes[8] -ne 0x41 -or $packet.Bytes[9] -ne 0x42 -or
    $packet.Bytes[10] -ne 0x43 -or
    ($packet.Bytes[11..15] | Where-Object { $_ -ne 0 }).Count -ne 0) {
    throw 'DSPQueue message packet encoding is incorrect.'
}
$emptyPacket = & $layout.NewMessagePacket ([byte[]]@())
if ($emptyPacket.PacketLength -ne 8 -or $emptyPacket.Flags -ne 0x10) {
    throw 'DSPQueue empty packet encoding is incorrect.'
}
foreach ($test in @(
    { & $layout.NewMessagePacket ([byte[]]::new(65537)) },
    { & $layout.NewMessagePacket ([byte[]]::new(9)) 0 16 },
    { & $layout.NewMessagePacket ([byte[]]@()) 256 }
)) {
    $rejected = $false
    try { [void](& $test) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid DSPQueue packet was accepted.' }
}

[pscustomobject]@{
    Parsed = $true
    DefaultArenaBytes = $arena.TotalBytes
    HeaderOffsetsVerified = $true
    V2FlagsVerified = $true
    MessagePacketVerified = $true
    InvalidInputsRejected = $true
    Passed = $true
}
