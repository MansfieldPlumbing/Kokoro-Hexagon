#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Serial,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,31}$')][string] $DeviceLabel,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_.]+$')]
    [string] $Package = 'dev.mansfieldplumbing.androidsma.preview'
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..'))
$adb = (Get-Command adb -CommandType Application -ErrorAction Stop |
    Select-Object -First 1).Source
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$destination = [IO.Path]::Combine($repo, 'build', 'device-scripts', "$stamp-$DeviceLabel")
if (Test-Path -LiteralPath $destination) { throw 'The recovery snapshot already exists.' }

function Invoke-AdbText([string[]] $Arguments) {
    $result = & $adb -s $Serial @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { throw "ADB inventory failed for $DeviceLabel." }
    return @($result)
}

function Copy-DeviceFile([string[]] $Arguments, [string] $RelativePath) {
    $target = [IO.Path]::GetFullPath([IO.Path]::Combine($destination, $RelativePath))
    if (-not $target.StartsWith($destination + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) { throw 'Device path escaped the snapshot.' }
    $parent = [IO.Path]::GetDirectoryName($target)
    [void][IO.Directory]::CreateDirectory($parent)

    $start = [Diagnostics.ProcessStartInfo]::new($adb)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($part in @('-s', $Serial, 'exec-out') + $Arguments) {
        [void]$start.ArgumentList.Add($part)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stream = $null
    try {
        if (-not $process.Start()) { throw 'ADB could not start.' }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = [byte[]]::new(65536)
        $total = 0L
        while (($read = $process.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt 8MB) { throw 'Device script exceeds the 8 MiB recovery limit.' }
            $stream.Write($buffer, 0, $read)
        }
        $stream.Dispose(); $stream = $null
        if (-not $process.WaitForExit(30000) -or $process.ExitCode -ne 0) {
            throw "ADB copy failed for $DeviceLabel."
        }
        return [pscustomobject]@{
            Source = $RelativePath
            Bytes = [IO.FileInfo]::new($target).Length
            Sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (-not $process.HasExited) { $process.Kill() }
        $process.Dispose()
    }
}

$sources = @(
    [pscustomobject]@{
        Label = 'private'
        Paths = @(Invoke-AdbText @('shell', 'run-as', $Package, 'find', 'files', '-type', 'f'))
    }
)
$shared = & $adb -s $Serial shell find /data/local/tmp/kokoro-fl -type f 2>$null
if ($LASTEXITCODE -eq 0) {
    $sources += [pscustomobject]@{ Label = 'shared-stage'; Paths = @($shared) }
}

$records = [Collections.Generic.List[object]]::new()
foreach ($source in $sources) {
    $paths = @($source.Paths | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' } | Sort-Object -Unique)
    foreach ($path in $paths) {
        if ($source.Label -eq 'private') {
            if ($path -notmatch '^files/[A-Za-z0-9_.@/-]+$' -or $path -match '(^|/)\.\.(/|$)') {
                throw 'Unsafe private script path in device inventory.'
            }
            $relative = "private/$path"
            $args = @('run-as', $Package, 'cat', $path)
        }
        else {
            if ($path -notmatch '^/data/local/tmp/kokoro-fl/[A-Za-z0-9_.@/-]+$' -or
                $path -match '(^|/)\.\.(/|$)') {
                throw 'Unsafe shared-stage script path in device inventory.'
            }
            $relative = 'shared-stage/' + $path.Substring('/data/local/tmp/kokoro-fl/'.Length)
            $args = @('cat', $path)
        }
        $records.Add((Copy-DeviceFile $args $relative))
    }
}

$manifest = [pscustomobject]@{
    DeviceLabel = $DeviceLabel
    Package = $Package
    CapturedUtc = $stamp
    Scripts = @($records)
}
$manifestPath = [IO.Path]::Combine($destination, 'manifest.json')
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5))
[pscustomobject]@{
    Snapshot = $destination
    ScriptCount = $records.Count
    PrivateCount = @($records | Where-Object Source -Like 'private/*').Count
    SharedCount = @($records | Where-Object Source -Like 'shared-stage/*').Count
}
