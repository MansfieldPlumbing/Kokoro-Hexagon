using module ./StudentSourceInventory.psm1
using module ./StudentTeacherObservation.psm1
#requires -Version 7.4

[CmdletBinding()]
param(
    [string] $BankPath = (Join-Path $PSScriptRoot '../data/source-bank'),
    [string] $CheckpointDirectory
)

enum StudentRetainedFindingKind {
    MissingFile
    MissingChecksum
    UnmappedFile
    ReadFailure
    ExtentContradiction
    DigestContradiction
    TensorPayloadContradiction
    TensorDecodeFailure
}

class StudentRetainedObject {
    [string] $Path
    [long] $Bytes
    [string] $Digest
    [long] $TensorBytes
    [string] $TensorDigest
    [System.Collections.Generic.List[StudentSourceUnit]] $Sources = [System.Collections.Generic.List[StudentSourceUnit]]::new()
}

class StudentRetainedFinding {
    [StudentRetainedFindingKind] $Kind
    [StudentRetainedObject] $File
    [StudentSourceUnit] $Source
    [Exception] $Error
    [StudentRetainedObject[]] $ContentCandidates = @()

    StudentRetainedFinding([StudentRetainedFindingKind] $kind, [StudentRetainedObject] $file,
        [StudentSourceUnit] $source, [Exception] $error) {
        $this.Kind = $kind
        $this.File = $file
        $this.Source = $source
        $this.Error = $error
    }
}

enum StudentActivationBearingKind {
    VerifiedPayload
    MissingPayload
    UnverifiedPayload
    ExtentContradiction
}

class StudentActivationBearing {
    [StudentStockActivation] $Activation
    [StudentRetainedObject] $File
    [StudentActivationBearingKind] $Status
    [StudentStockFrameClock] $Clock
}

class StudentRetainedField {
    [StudentSourceInventory] $Inventory
    [System.Collections.Generic.Dictionary[string, StudentRetainedObject]] $Files
    [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[StudentRetainedObject]]] $ByDigest =
        [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[StudentRetainedObject]]]::new([StringComparer]::Ordinal)
    [System.Collections.Generic.List[StudentRetainedFinding]] $Findings = [System.Collections.Generic.List[StudentRetainedFinding]]::new()
    [long] $BytesRead
    [long] $FilesRead
    [long] $FilesResumed
    [long] $VerifiedSources
    [long] $VerifiedTensorPayloads
    [long] $TensorBytesRead
    [long] $TensorBytesReuse
    [object] $Speech
    [System.Collections.Generic.List[StudentActivationBearing]] $ActivationBearings =
        [System.Collections.Generic.List[StudentActivationBearing]]::new()
    [long] $RepeatedActivationBytes
    [long] $PathlessSources
    [timespan] $Elapsed
}

$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()
$root = (Resolve-Path -LiteralPath $BankPath).ProviderPath
$field = [StudentRetainedField]::new()
$field.Inventory = Open-StudentSourceInventory (Join-Path $root 'sources.bin')
$paths = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$field.Files = [Collections.Generic.Dictionary[string, StudentRetainedObject]]::new($paths)
$enumeration = [IO.EnumerationOptions]::new()
$enumeration.RecurseSubdirectories = $true
$enumeration.IgnoreInaccessible = $false
$enumeration.AttributesToSkip = [IO.FileAttributes]::None
$tensorPaths = [Collections.Generic.HashSet[string]]::new($paths)
foreach ($bufferRoot in Get-StudentStockBufferRoots $root) {
    if (![IO.Directory]::Exists($bufferRoot)) { continue }
    foreach ($path in [IO.Directory]::EnumerateFiles($bufferRoot, '*.gz', $enumeration)) {
        $null = $tensorPaths.Add($path)
    }
}
foreach ($path in [IO.Directory]::EnumerateFiles($root, '*', $enumeration)) {
    $file = [StudentRetainedObject]::new()
    $file.Path = $path
    $field.Files.Add($file.Path, $file)
}
foreach ($path in $tensorPaths) {
    if ($field.Files.ContainsKey($path)) { continue }
    $file = [StudentRetainedObject]::new()
    $file.Path = $path
    $field.Files.Add($path, $file)
}

foreach ($source in $field.Inventory.Units.Values) {
    if (!$source.Path) {
        $field.PathlessSources++
        continue
    }
    $path = [IO.Path]::GetFullPath($source.Path, $root)
    $file = $null
    if (!$field.Files.TryGetValue($path, [ref]$file)) {
        $file = [StudentRetainedObject]::new()
        $file.Path = $path
        $field.Files.Add($path, $file)
    }
    $file.Sources.Add($source)
}

$tensorBuffer = [byte[]]::new(1MB)
$decoded = [Collections.Generic.Dictionary[string, StudentRetainedObject]]::new([StringComparer]::Ordinal)
$checkpoint = if ($CheckpointDirectory) { [IO.Directory]::CreateDirectory($CheckpointDirectory).FullName }
foreach ($file in $field.Files.Values) {
    $cached = $false
    $tensor = $tensorPaths.Contains($file.Path)
    $entry = $null
    $stamp = [IO.FileInfo]::new($file.Path)
    if ($checkpoint -and $stamp.Exists) {
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($file.Path)))
        $entry = Join-Path $checkpoint "$key.bin"
        $length = $stamp.Length
        $modified = $stamp.LastWriteTimeUtc.Ticks
        $created = $stamp.CreationTimeUtc.Ticks
        if ([IO.File]::Exists($entry)) {
            $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($entry))
            try {
                if ($reader.ReadString() -ceq 'StudentRetainedFile/1' -and $reader.ReadString() -ceq $file.Path -and
                    $reader.ReadInt64() -eq $length -and $reader.ReadInt64() -eq $modified -and
                    $reader.ReadInt64() -eq $created -and $reader.ReadBoolean() -eq $tensor) {
                    $file.Digest = $reader.ReadString()
                    $file.TensorDigest = $reader.ReadString()
                    $file.TensorBytes = $reader.ReadInt64()
                    $file.Bytes = $length
                    $cached = $file.Digest.Length -eq 64 -and (!$tensor -or $file.TensorDigest.Length -eq 64)
                }
            } catch [IO.IOException], [FormatException] {
                Write-Information "Rechecking unreadable checkpoint for $($file.Path)" -InformationAction Continue
            } finally { $reader.Dispose() }
        }
    }
    if ($cached) {
        $field.FilesResumed++
    } else {
    $file.TensorBytes = 0
    $file.TensorDigest = ''
    try {
        $stream = [IO.FileStream]::new($file.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
        try {
            $file.Digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
            $file.Bytes = $stream.Position
        } finally { $stream.Dispose() }
    } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        foreach ($source in $file.Sources) {
            $field.Findings.Add([StudentRetainedFinding]::new('MissingFile', $file, $source, $_.Exception))
        }
        if (!$file.Sources.Count) {
            $field.Findings.Add([StudentRetainedFinding]::new('MissingFile', $file, $null, $_.Exception))
        }
        continue
    } catch [IO.IOException], [UnauthorizedAccessException] {
        $field.Findings.Add([StudentRetainedFinding]::new('ReadFailure', $file, $null, $_.Exception))
        continue
    }
    }

    $field.FilesRead++
    $field.BytesRead += $file.Bytes
    if (!$field.ByDigest.ContainsKey($file.Digest)) {
        $field.ByDigest.Add($file.Digest, [Collections.Generic.List[StudentRetainedObject]]::new())
    }
    $field.ByDigest[$file.Digest].Add($file)
    if ($tensor) {
        try {
            if ($cached) {
                $decoded.TryAdd($file.Digest, $file) | Out-Null
            } elseif ($decoded.ContainsKey($file.Digest)) {
                $previous = $decoded[$file.Digest]
                $file.TensorDigest = $previous.TensorDigest
                $file.TensorBytes = $previous.TensorBytes
                $field.TensorBytesReuse += $file.TensorBytes
            } else {
                $stream = [IO.File]::OpenRead($file.Path)
                try {
                    # Verify the exact compressed bytes used for reuse before releasing the read lock.
                    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) -cne $file.Digest) {
                        throw [IO.IOException]::new('Compressed payload changed between reads.')
                    }
                    $stream.Position = 0
                    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
                    try {
                        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
                        try {
                            while (($read = $gzip.Read($tensorBuffer, 0, $tensorBuffer.Length)) -gt 0) {
                                $hash.AppendData($tensorBuffer, 0, $read)
                                $file.TensorBytes += $read
                                $field.TensorBytesRead += $read
                            }
                            $file.TensorDigest = [Convert]::ToHexString($hash.GetHashAndReset())
                        } finally { $hash.Dispose() }
                    } finally { $gzip.Dispose() }
                } finally { $stream.Dispose() }
                $decoded.Add($file.Digest, $file)
            }
            if ($file.TensorDigest -cne [IO.Path]::GetFileNameWithoutExtension($file.Path)) {
                $field.Findings.Add([StudentRetainedFinding]::new('TensorPayloadContradiction', $file, $null, $null))
            } else { $field.VerifiedTensorPayloads++ }
        } catch [IO.IOException], [IO.InvalidDataException], [UnauthorizedAccessException] {
            $field.Findings.Add([StudentRetainedFinding]::new('TensorDecodeFailure', $file, $null, $_.Exception))
        }
    } elseif (!$file.Sources.Count) {
        $field.Findings.Add([StudentRetainedFinding]::new('UnmappedFile', $file, $null, $null))
    }
    if ($entry -and !$cached -and (!$tensor -or $file.TensorDigest)) {
        $stamp.Refresh()
        if ($stamp.Exists -and $stamp.Length -eq $file.Bytes -and $stamp.LastWriteTimeUtc.Ticks -eq $modified -and
            $stamp.CreationTimeUtc.Ticks -eq $created) {
            $temporary = "$entry.$([guid]::NewGuid()).partial"
            $writer = [IO.BinaryWriter]::new([IO.File]::Open($temporary,'CreateNew','Write','None'))
            try {
                $writer.Write('StudentRetainedFile/1')
                $writer.Write($file.Path)
                $writer.Write($file.Bytes)
                $writer.Write($modified)
                $writer.Write($created)
                $writer.Write($tensor)
                $writer.Write($file.Digest)
                $writer.Write([string]$file.TensorDigest)
                $writer.Write($file.TensorBytes)
                $writer.Flush()
                $writer.BaseStream.Flush($true)
            } finally { $writer.Dispose() }
            [IO.File]::Move($temporary,$entry,$true)
        }
    }
    if ($checkpoint -and $field.FilesRead % 250 -eq 0) {
        Write-Information ("{0:u} Scanned {1}/{2} files, resumed {3}, covered {4:N0} bytes." -f
            [datetime]::UtcNow,$field.FilesRead,$field.Files.Count,$field.FilesResumed,$field.BytesRead) -InformationAction Continue
    }
    foreach ($source in $file.Sources) {
        if ($source.Length -ne $file.Bytes) {
            $field.Findings.Add([StudentRetainedFinding]::new('ExtentContradiction', $file, $source, $null))
        }
        if (!$source.Checksum) {
            $field.Findings.Add([StudentRetainedFinding]::new('MissingChecksum', $file, $source, $null))
        } elseif ($source.Checksum -ine $file.Digest) {
            $field.Findings.Add([StudentRetainedFinding]::new('DigestContradiction', $file, $source, $null))
        } elseif ($source.Length -eq $file.Bytes) {
            $field.VerifiedSources++
        }
    }
}
foreach ($finding in $field.Findings) {
    if ($finding.Kind -ne [StudentRetainedFindingKind]::MissingFile -or !$finding.Source.Checksum) { continue }
    $candidates = $field.ByDigest[$finding.Source.Checksum.ToUpperInvariant()]
    $finding.ContentCandidates = @(foreach ($candidate in $candidates) {
        if ($candidate -and $candidate.Bytes -eq $finding.Source.Length) { $candidate }
    })
}
$field.Speech = & "$PSScriptRoot/Open-StudentSpeechInvestigation.ps1" -BankPath $root -Inventory $field.Inventory
$seenPayloads = [Collections.Generic.HashSet[StudentRetainedObject]]::new()
foreach ($comparison in $field.Speech.Comparisons) {
    $teacher = $comparison.Teacher
    $executions = @($teacher.StockExecution, $teacher.StockExecution.FrontStateReplay, $teacher.ProceduralExecution)
    foreach ($intervention in $teacher.ResidualInterventions) { $executions += $intervention.Outcome }
    foreach ($execution in $executions) {
        if (!$execution) { continue }
        foreach ($activation in $execution.Activations) {
            $bearing = [StudentActivationBearing]::new()
            $bearing.Activation = $activation
            $bearing.Clock = $activation.FrameClock()
            $bearing.File = $field.Files[[IO.Path]::GetFullPath($activation.Path, $root)]
            $width = if ($activation.TypeCode -eq 2) { 8L } else { 4L }
            $bytes = $width * $activation.Count
            $bearing.Status = if (!$bearing.File) { 'MissingPayload' }
                elseif ($bearing.File.TensorDigest -cne $activation.Checksum) { 'UnverifiedPayload' }
                elseif ($bearing.File.TensorBytes -ne $bytes) { 'ExtentContradiction' }
                else {
                    if (!$seenPayloads.Add($bearing.File)) { $field.RepeatedActivationBytes += $bytes }
                    'VerifiedPayload'
                }
            $field.ActivationBearings.Add($bearing)
        }
    }
}
$field.Elapsed = $clock.Elapsed
$field
