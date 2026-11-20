#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfileLayout,
    [Parameter(Mandatory)][string]$DeviceOutput
)

$ErrorActionPreference = 'Stop'
$profile = Get-Content -LiteralPath $ProfileLayout -Raw | ConvertFrom-Json
# The lockstep slots follow the PMU header by 60,928 bytes. Both offsets
# are relative to the generator's 128-byte-aligned workspace base.
$lockstepRelative = 60928
$scratch = [long]$profile.LockstepTelemetryOffset - $lockstepRelative
$stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $DeviceOutput).Path)
$reader = [IO.BinaryReader]::new($stream)
try {
    if ($scratch -lt 0 -or $scratch + 191 + $lockstepRelative + 32 * $profile.LockstepThreads -gt $stream.Length) {
        throw 'Timing data falls outside the captured output.'
    }
    $headers = @(foreach ($bias in 64..191) {
        $stream.Position = $scratch + $bias
        if ($reader.ReadUInt32() -eq 0x31554D50) { $stream.Position - 4 }
    })
    if ($headers.Count -ne 1) { throw 'Expected exactly one PMU timing header.' }
    $header = $headers[0]
    for ($category = 0; $category -lt $profile.Categories.Count; $category++) {
        $stream.Position = $header + 256 + 64 * $category + 32
        $ticks = $reader.ReadUInt64()
        $cycles = $reader.ReadUInt64()
        $marks = $reader.ReadUInt32()
        [pscustomobject]@{Scope='Controller'; Thread=$null; Interval=$profile.Categories[$category]; Ticks=$ticks; Milliseconds=$ticks/19200; Cycles=$cycles; Marks=$marks}
    }
    $intervals = 'LockWait','MatrixHeld','NeighborWait','Fill','Combine','MeanOutput','InputDma'
    for ($thread = 0; $thread -lt $profile.LockstepThreads; $thread++) {
        $stream.Position = $header + $lockstepRelative + 32 * $thread
        foreach ($interval in $intervals) {
            $ticks = $reader.ReadUInt32()
            [pscustomobject]@{Scope='LockstepWorker'; Thread=$thread; Interval=$interval; Ticks=$ticks; Milliseconds=$ticks/19200; Cycles=$null; Marks=$null}
        }
    }
} finally {
    $reader.Dispose()
}
