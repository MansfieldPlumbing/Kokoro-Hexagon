#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('status','ping','receipt')]
    [string] $Operation = 'status',
    [hashtable] $Payload = @{},
    [switch] $Interactive,
    [ValidateRange(1000,120000)]
    [int] $TimeoutMilliseconds = 15000
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$aoa = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match '^USB\\VID_18D1&PID_2D0[01](?:&|\\)'
})

if ($aoa.Count -eq 0) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'UsbAoa.ps1') -Start -StopAdb -WaitMilliseconds $TimeoutMilliseconds
    if ($LASTEXITCODE) { throw 'AOA negotiation failed.' }
}

$interfaceGuid = '{0cf010b1-07a8-4b28-b1c9-a2cfde8c9953}'
$interfaceRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$interfaceGuid"
$doorKey = @(Get-ChildItem -LiteralPath $interfaceRoot -ErrorAction Stop | Where-Object {
    $_.PSChildName -match 'VID_18D1&PID_2D0[01]'
})
if ($doorKey.Count -ne 1) {
    throw "Expected one live Android accessory WinUSB door; found $($doorKey.Count)."
}
$door = $doorKey[0].PSChildName -replace '^##\?#', '\\?\'

$handle = [IO.File]::OpenHandle(
    $door,
    [IO.FileMode]::Open,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::ReadWrite,
    [IO.FileOptions]::Asynchronous
)

[string]$suffix = [Guid]::NewGuid().ToString('N')
$assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
    [Reflection.AssemblyName]::new("AoaConsole.Native.$suffix"),
    [Reflection.Emit.AssemblyBuilderAccess]::Run
)
$module = $assembly.DefineDynamicModule("AoaConsole.Native.$suffix")
$type = $module.DefineType(
    "AoaConsole.Native_$suffix",
    [Reflection.TypeAttributes]'Public,Abstract,Sealed'
)
$flags = [Reflection.MethodAttributes]'Public,Static,PinvokeImpl'
$calling = [Runtime.InteropServices.CallingConvention]::Winapi
$charset = [Runtime.InteropServices.CharSet]::None

$signatures = @(
    @('WinUsb_Initialize', [int32], [Type[]]@([IntPtr],[IntPtr])),
    @('WinUsb_QueryInterfaceSettings', [int32], [Type[]]@([IntPtr],[byte],[IntPtr])),
    @('WinUsb_QueryPipe', [int32], [Type[]]@([IntPtr],[byte],[byte],[IntPtr])),
    @('WinUsb_SetPipePolicy', [int32], [Type[]]@([IntPtr],[byte],[uint32],[uint32],[IntPtr])),
    @('WinUsb_ReadPipe', [int32], [Type[]]@([IntPtr],[byte],[IntPtr],[uint32],[IntPtr],[IntPtr])),
    @('WinUsb_WritePipe', [int32], [Type[]]@([IntPtr],[byte],[IntPtr],[uint32],[IntPtr],[IntPtr])),
    @('WinUsb_Free', [int32], [Type[]]@([IntPtr]))
)
foreach ($signature in $signatures) {
    $method = $type.DefinePInvokeMethod(
        $signature[0], 'winusb.dll', $signature[0], $flags,
        [Reflection.CallingConventions]::Standard,
        $signature[1], $signature[2], $calling, $charset
    )
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
}
$native = $type.CreateType()

[IntPtr[]]$usbCell = [IntPtr[]]::new(1)
$usbCellPin = [Runtime.InteropServices.GCHandle]::Alloc($usbCell, [Runtime.InteropServices.GCHandleType]::Pinned)
[IntPtr]$usb = [IntPtr]::Zero

try {
    if (-not $native::WinUsb_Initialize($handle.DangerousGetHandle(), $usbCellPin.AddrOfPinnedObject())) {
        throw "WinUsb_Initialize failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    $usb = $usbCell[0]

    [byte[]]$descriptor = [byte[]]::new(9)
    $descriptorPin = [Runtime.InteropServices.GCHandle]::Alloc($descriptor, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        if (-not $native::WinUsb_QueryInterfaceSettings($usb, 0, $descriptorPin.AddrOfPinnedObject())) {
            throw 'WinUsb_QueryInterfaceSettings failed.'
        }
    }
    finally { $descriptorPin.Free() }

    [byte]$pipeIn = 0
    [byte]$pipeOut = 0
    for ([byte]$index = 0; $index -lt $descriptor[4]; $index++) {
        [byte[]]$pipe = [byte[]]::new(12)
        $pipePin = [Runtime.InteropServices.GCHandle]::Alloc($pipe, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            if (-not $native::WinUsb_QueryPipe($usb, 0, $index, $pipePin.AddrOfPinnedObject())) {
                throw "WinUsb_QueryPipe failed for index $index."
            }
        }
        finally { $pipePin.Free() }
        [int]$pipeType = [BitConverter]::ToInt32($pipe, 0)
        [byte]$pipeId = $pipe[4]
        if ($pipeType -eq 2) {
            if (($pipeId -band 0x80) -ne 0) { $pipeIn = $pipeId } else { $pipeOut = $pipeId }
        }
    }
    if ($pipeIn -eq 0 -or $pipeOut -eq 0) {
        throw "Bulk endpoint discovery failed (IN=0x$($pipeIn.ToString('X2')) OUT=0x$($pipeOut.ToString('X2')))."
    }

    [uint32[]]$timeout = @([uint32]$TimeoutMilliseconds)
    $timeoutPin = [Runtime.InteropServices.GCHandle]::Alloc($timeout, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        foreach ($pipeId in @($pipeIn, $pipeOut)) {
            if (-not $native::WinUsb_SetPipePolicy($usb, $pipeId, 3, 4, $timeoutPin.AddrOfPinnedObject())) {
                throw "Could not set timeout on pipe 0x$($pipeId.ToString('X2'))."
            }
        }
    }
    finally { $timeoutPin.Free() }

    function Write-AoaBytes([byte[]]$Bytes) {
        [uint32[]]$written = [uint32[]]::new(1)
        $bytesPin = [Runtime.InteropServices.GCHandle]::Alloc($Bytes, [Runtime.InteropServices.GCHandleType]::Pinned)
        $writtenPin = [Runtime.InteropServices.GCHandle]::Alloc($written, [Runtime.InteropServices.GCHandleType]::Pinned)
        try {
            if (-not $native::WinUsb_WritePipe($usb, $pipeOut, $bytesPin.AddrOfPinnedObject(), [uint32]$Bytes.Length, $writtenPin.AddrOfPinnedObject(), [IntPtr]::Zero)) {
                throw "AOA bulk OUT failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            }
            if ($written[0] -ne $Bytes.Length) { throw "AOA short write: $($written[0])/$($Bytes.Length)." }
        }
        finally { $writtenPin.Free(); $bytesPin.Free() }
    }

    function Read-AoaBytes([int]$Count) {
        [byte[]]$result = [byte[]]::new($Count)
        [int]$offset = 0
        while ($offset -lt $Count) {
            [byte[]]$chunk = [byte[]]::new($Count - $offset)
            [uint32[]]$read = [uint32[]]::new(1)
            $chunkPin = [Runtime.InteropServices.GCHandle]::Alloc($chunk, [Runtime.InteropServices.GCHandleType]::Pinned)
            $readPin = [Runtime.InteropServices.GCHandle]::Alloc($read, [Runtime.InteropServices.GCHandleType]::Pinned)
            try {
                if (-not $native::WinUsb_ReadPipe($usb, $pipeIn, $chunkPin.AddrOfPinnedObject(), [uint32]$chunk.Length, $readPin.AddrOfPinnedObject(), [IntPtr]::Zero)) {
                    throw "AOA bulk IN failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
                }
            }
            finally { $readPin.Free(); $chunkPin.Free() }
            if ($read[0] -eq 0) { throw 'AOA bulk IN returned zero bytes.' }
            [Buffer]::BlockCopy($chunk, 0, $result, $offset, [int]$read[0])
            $offset += [int]$read[0]
        }
        return ,$result
    }

    function Invoke-AoaMessage([hashtable]$Message) {
        [string]$json = $Message | ConvertTo-Json -Depth 8 -Compress
        [byte[]]$body = [Text.Encoding]::UTF8.GetBytes($json)
        if ($body.Length -gt 262144) { throw "AOA request frame is too large: $($body.Length)." }
        [byte[]]$frame = [byte[]]::new(4 + $body.Length)
        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]$body.Length), 0, $frame, 0, 4)
        [Buffer]::BlockCopy($body, 0, $frame, 4, $body.Length)
        Write-AoaBytes $frame
        [byte[]]$header = Read-AoaBytes 4
        [uint32]$replyLength = [BitConverter]::ToUInt32($header, 0)
        if ($replyLength -gt 262144) { throw "AOA reply frame is too large: $replyLength." }
        [byte[]]$reply = Read-AoaBytes ([int]$replyLength)
        return [Text.Encoding]::UTF8.GetString($reply) | ConvertFrom-Json
    }

    Write-Host ("AOA READY  IN=0x{0:X2} OUT=0x{1:X2}" -f $pipeIn, $pipeOut)
    if ($Interactive) {
        while ($true) {
            $line = Read-Host 'kokoro'
            if ($line -in @('exit','quit')) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $request = @{ schema=1; id=[Guid]::NewGuid().ToString('N'); operation='speak'; payload=@{ text=$line } }
                $result = Invoke-AoaMessage $request
                if ($result.ok) { $result | Out-Host } else { Write-Error $result.error }
            }
            catch { Write-Error $_ }
        }
    }
    else {
        $request = @{ schema=1; id=[Guid]::NewGuid().ToString('N'); operation=$Operation; payload=$Payload }
        $result = Invoke-AoaMessage $request
        if (-not $result.ok) { throw $result.error }
        $result
    }
}
finally {
    if ($usb -ne [IntPtr]::Zero) { [void]$native::WinUsb_Free($usb) }
    $usbCellPin.Free()
    $handle.Dispose()
}
