# Typed managed owner of a read-only assembly resource mapping. The caller owns
# this object for the session; its pointer is borrowed only until Close.
class KokoroMappedPayload {
    hidden [IO.FileStream] $File
    hidden [IO.MemoryMappedFiles.MemoryMappedFile] $Mapping
    hidden [IO.MemoryMappedFiles.MemoryMappedViewAccessor] $View
    hidden [IntPtr] $Address
    [long] $Bytes
    [bool] $Closed

    # Expected length, identity and offsets come from the verified activation
    # descriptor. Full signature/hash validation belongs to activation, once.
    KokoroMappedPayload([string] $Path, [long] $Offset, [long] $Length, [long] $AssemblyBytes, [long] $IdentityOffset, [byte[]] $Identity) {
        if ($Offset -lt 0L -or $Length -lt 1L -or $Length -gt [long][int]::MaxValue) { throw [ArgumentOutOfRangeException]::new('Length') }
        if ([byte[]]$null -eq $Identity -or $Identity.Length -ne 16) { throw [ArgumentException]::new('Expected identity must have 16 bytes.') }
        $this.Closed = $true
        try {
            $this.File = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            if ($this.File.Length -ne $AssemblyBytes) { throw [IO.InvalidDataException]::new('Activated assembly length differs.') }
            if ($Offset -gt $this.File.Length -or $Length -gt $this.File.Length - $Offset) { throw [IO.InvalidDataException]::new('Resource extent exceeds assembly.') }
            if ($IdentityOffset -lt 0L -or $IdentityOffset -gt $this.File.Length - 16L) { throw [IO.InvalidDataException]::new('Identity extent exceeds assembly.') }
            $this.File.Position = $IdentityOffset
            [byte[]] $identityBytes = [byte[]]::new(16)
            if ($this.File.Read($identityBytes, 0, 16) -ne 16) { throw [IO.InvalidDataException]::new('Activated assembly identity is truncated.') }
            for ([int] $index = 0; $index -lt 16; $index++) {
                if ($identityBytes[$index] -ne $Identity[$index]) { throw [IO.InvalidDataException]::new('Activated assembly identity differs.') }
            }
            $this.Mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($this.File, [string]$null, 0L, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read, [IO.HandleInheritability]::None, $true)
            $this.View = $this.Mapping.CreateViewAccessor($Offset, $Length, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
            $this.Address = [IntPtr]::Add($this.View.SafeMemoryMappedViewHandle.DangerousGetHandle(), [int]$this.View.PointerOffset)
            $this.Bytes = $Length
            $this.Closed = $false
        }
        finally { if ($this.Closed) { $this.Close() } }
    }

    [IntPtr] GetPointer() {
        if ($this.Closed) { throw [ObjectDisposedException]::new('KokoroMappedPayload') }
        return $this.Address
    }

    [void] Close() {
        $this.Closed = $true
        $this.Address = [IntPtr]::Zero
        if ([IO.MemoryMappedFiles.MemoryMappedViewAccessor]$null -ne $this.View) { $this.View.Dispose(); $this.View = $null }
        if ([IO.MemoryMappedFiles.MemoryMappedFile]$null -ne $this.Mapping) { $this.Mapping.Dispose(); $this.Mapping = $null }
        if ([IO.FileStream]$null -ne $this.File) { $this.File.Dispose(); $this.File = $null }
    }
}
