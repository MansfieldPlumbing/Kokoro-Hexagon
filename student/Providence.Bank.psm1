#requires -Version 7.4
# Providence retained-file observation. Exact byte verification is not semantic
# acquisition. The resulting typed observation can feed the live field immediately.

class ProvidenceFileObservation {
    [string] $Path
    [long] $Bytes
    [string] $Digest
    [bool] $TensorPayload
    [long] $DecodedBytes
    [string] $DecodedDigest
    [bool] $Verified
    [bool] $FromCheckpoint
    [object] $CanonicalSource
    [string] $Failure
}

function Read-ProvidenceRetainedFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[string]$CheckpointDirectory,
          [switch]$TensorPayload,[object]$CanonicalSource)
    $full=[IO.Path]::GetFullPath($Path)
    $entry=$null
    $f=[IO.FileInfo]::new($full)
    if(!$f.Exists){throw "File missing: $full"}
    $initialLength=$f.Length
    $initialModified=$f.LastWriteTimeUtc.Ticks
    $initialCreated=$f.CreationTimeUtc.Ticks
    $out=[ProvidenceFileObservation]::new()
    $out.Path=$full;$out.Bytes=$f.Length;$out.TensorPayload=[bool]$TensorPayload
    $out.CanonicalSource=$CanonicalSource
    if($CheckpointDirectory){
        $root=[IO.Directory]::CreateDirectory($CheckpointDirectory).FullName
        $name=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($full)))
        $entry=Join-Path $root "$name.bin"
        if([IO.File]::Exists($entry)){
            $reader=[IO.BinaryReader]::new([IO.File]::OpenRead($entry))
            try {
                $version=$reader.ReadString()
                if($version -ceq 'StudentRetainedFile/1' -and $reader.ReadString() -ceq $full -and
                   $reader.ReadInt64() -eq $f.Length -and $reader.ReadInt64() -eq $f.LastWriteTimeUtc.Ticks -and
                   $reader.ReadInt64() -eq $f.CreationTimeUtc.Ticks -and $reader.ReadBoolean() -eq [bool]$TensorPayload){
                    $out.Digest=$reader.ReadString();$out.DecodedDigest=$reader.ReadString()
                    $out.DecodedBytes=$reader.ReadInt64()
                    if($out.Digest.Length -eq 64 -and (!$TensorPayload -or $out.DecodedDigest.Length -eq 64)){
                        $out.FromCheckpoint=$true
                    }
                }
            } catch [IO.IOException], [FormatException] {
                $out.FromCheckpoint=$false
            } finally {$reader.Dispose()}
        }
    }
    if(!$out.FromCheckpoint){
        $input=[IO.FileStream]::new($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,
            [IO.FileShare]::Read,1048576,[IO.FileOptions]::SequentialScan)
        try {$out.Digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($input))}
        finally {$input.Dispose()}
        if($TensorPayload){
            $input=[IO.File]::OpenRead($full)
            $gzip=[IO.Compression.GZipStream]::new($input,[IO.Compression.CompressionMode]::Decompress)
            $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                $buf=[byte[]]::new(1048576)
                while(($n=$gzip.Read($buf,0,$buf.Length)) -gt 0){$hash.AppendData($buf,0,$n);$out.DecodedBytes+=$n}
                $out.DecodedDigest=[Convert]::ToHexString($hash.GetHashAndReset())
            } finally {$hash.Dispose();$gzip.Dispose();$input.Dispose()}
        }
        $f.Refresh()
        if($entry -and $f.Exists -and $f.Length -eq $initialLength -and
           $f.LastWriteTimeUtc.Ticks -eq $initialModified -and $f.CreationTimeUtc.Ticks -eq $initialCreated){
            $tmp="$entry.$([guid]::NewGuid().ToString('N')).partial"
            $writer=[IO.BinaryWriter]::new([IO.File]::Open($tmp,'CreateNew','Write','None'))
            try {
                # Compatible with Student's existing resumable checksum scanner.
                $writer.Write('StudentRetainedFile/1');$writer.Write($full);$writer.Write($f.Length)
                $writer.Write($f.LastWriteTimeUtc.Ticks);$writer.Write($f.CreationTimeUtc.Ticks)
                $writer.Write([bool]$TensorPayload);$writer.Write($out.Digest)
                $writer.Write([string]$out.DecodedDigest);$writer.Write($out.DecodedBytes)
                $writer.Flush();$writer.BaseStream.Flush($true)
            } finally {$writer.Dispose()}
            [IO.File]::Move($tmp,$entry,$true)
        } elseif($entry){
            throw 'Source changed during the file verification; do not checkpoint stale bytes'
        }
    }
    if($TensorPayload){
        $expected=[IO.Path]::GetFileNameWithoutExtension($full)
        $out.Verified=$out.DecodedDigest -ceq $expected
        if(!$out.Verified){$out.Failure='Decoded tensor digest disagrees with payload filename'}
    } else {$out.Verified=$out.Digest.Length -eq 64}
    if($CanonicalSource -and $CanonicalSource.Checksum){
        if($out.Digest -cne $CanonicalSource.Checksum){$out.Verified=$false;$out.Failure='Original source digest disagreement'}
    }
    return $out
}
Export-ModuleMember -Function Read-ProvidenceRetainedFile
