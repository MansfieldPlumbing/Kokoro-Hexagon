#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$AssemblyDirectory = [IO.Path]::GetFullPath([IO.Path]::Combine(
        $PSScriptRoot, '..', 'build', 'arm64-v8a', 'managed', 'by-name'))
)
$ErrorActionPreference = 'Stop'
$directory = (Resolve-Path -LiteralPath $AssemblyDirectory).Path
$files = @(Get-ChildItem -LiteralPath $directory -Filter '*.dll' -File)
if ($files.Count -eq 0) { throw 'The assembly archive is empty.' }
$native = [Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $stream = [IO.File]::OpenRead($file.FullName)
    $reader = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $header = $reader.PEHeaders.CorHeader
        if ($null -eq $header -or -not $reader.HasMetadata -or
            $header.ManagedNativeHeaderDirectory.Size -ne 0 -or
            ($header.Flags -band [Reflection.PortableExecutable.CorFlags]::ILOnly) -eq 0) {
            $native.Add($file.Name)
        }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}
if ($native.Count -gt 0) {
    throw "Assembly archive contains $($native.Count) non-IL-only images; ReadyToRun-free gate failed."
}
[pscustomobject]@{ AssemblyCount = $files.Count; NonIlOnlyCount = 0; Passed = $true }
