#requires -Version 7.4

class StudentSourceUnit {
    [string] $Id
    [string] $Kind
    [string] $Path
    [string] $Checksum
    [string] $PublisherUri
    [string] $Rights
    [string] $EvidenceGroup
    [long] $Start
    [long] $Length
    [double] $PublishedSeconds
    [int] $SampleRate
    [int] $Channels
    [long] $SampleCount
    [StudentSourceUnit] $Parent
    [StudentSourceUnit] $CorrespondingText
    [System.Collections.Generic.List[StudentSourceUnit]] $Children = [System.Collections.Generic.List[StudentSourceUnit]]::new()
}

class StudentSourceInventory {
    [System.Collections.Generic.Dictionary[string, StudentSourceUnit]] $Units =
        [System.Collections.Generic.Dictionary[string, StudentSourceUnit]]::new([StringComparer]::Ordinal)

    [void] Add([StudentSourceUnit] $Unit) {
        $this.Units.Add($Unit.Id, $Unit)
        if ($null -ne $Unit.Parent) {
            $Unit.Parent.Children.Add($Unit)
        }
    }
}

function Add-StudentSourceFile {
    param(
        [Parameter(Mandatory)][StudentSourceInventory] $Inventory,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $Path,
        [string] $PublisherUri,
        [string] $Rights,
        [string] $EvidenceGroup,
        [StudentSourceUnit] $Parent,
        [StudentSourceUnit] $CorrespondingText,
        [double] $PublishedSeconds
    )
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $unit = [StudentSourceUnit]::new()
    $unit.Id = $Id
    $unit.Kind = $Kind
    $unit.Path = $file.FullName
    $unit.Length = $file.Length
    $unit.Checksum = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $unit.PublisherUri = $PublisherUri
    $unit.Rights = $Rights
    $unit.EvidenceGroup = $EvidenceGroup
    $unit.Parent = $Parent
    $unit.CorrespondingText = $CorrespondingText
    $unit.PublishedSeconds = $PublishedSeconds
    $Inventory.Add($unit)
    $unit
}

function Save-StudentSourceInventory {
    param([StudentSourceInventory] $Inventory, [string] $Path)

    $path = [IO.Path]::GetFullPath($Path)
    $temporary = "$path.$([guid]::NewGuid()).partial"
    try {
        $writer = [IO.BinaryWriter]::new([IO.File]::Open($temporary, [IO.FileMode]::CreateNew))
        try {
            $writer.Write('StudentSourceInventory')
            $writer.Write([int]2)
            $writer.Write($Inventory.Units.Count)
            foreach ($unit in $Inventory.Units.Values) {
                foreach ($field in 'Id','Kind','Path','Checksum','PublisherUri','Rights','EvidenceGroup') {
                    $writer.Write([string]$unit.$field)
                }
                $writer.Write($unit.Start)
                $writer.Write($unit.Length)
                $writer.Write($unit.PublishedSeconds)
                $writer.Write($unit.SampleRate)
                $writer.Write($unit.Channels)
                $writer.Write($unit.SampleCount)
                $writer.Write([string]$unit.Parent.Id)
                $writer.Write([string]$unit.CorrespondingText.Id)
            }
        } finally {
            $writer.Dispose()
        }
        [IO.File]::Move($temporary, $path, $true)
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Open-StudentSourceInventory {
    param([Parameter(Mandatory)][string] $Path)

    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead((Convert-Path -LiteralPath $Path)))
    try {
        if ($reader.ReadString() -cne 'StudentSourceInventory') {
            throw 'Unsupported Student source inventory format.'
        }
        $version = $reader.ReadInt32()
        if ($version -notin 1, 2) { throw 'Unsupported Student source inventory version.' }
        $inventory = [StudentSourceInventory]::new()
        $references = [System.Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::Ordinal)
        $count = $reader.ReadInt32()
        if ($count -lt 0) { throw 'Invalid Student source inventory count.' }
        for ($i = 0; $i -lt $count; $i++) {
            $unit = [StudentSourceUnit]::new()
            foreach ($field in 'Id','Kind','Path','Checksum','PublisherUri','Rights','EvidenceGroup') {
                $unit.$field = $reader.ReadString()
            }
            $unit.Start = $reader.ReadInt64()
            $unit.Length = $reader.ReadInt64()
            $unit.PublishedSeconds = $reader.ReadDouble()
            if ($version -ge 2) {
                $unit.SampleRate = $reader.ReadInt32()
                $unit.Channels = $reader.ReadInt32()
                $unit.SampleCount = $reader.ReadInt64()
            }
            $references.Add($unit.Id, [string[]]@($reader.ReadString(), $reader.ReadString()))
            $inventory.Add($unit)
        }
        if ($reader.BaseStream.Position -ne $reader.BaseStream.Length) {
            throw 'Unexpected data after Student source inventory records.'
        }
        foreach ($unit in $inventory.Units.Values) {
            $parentId, $textId = $references[$unit.Id]
            if ($parentId) {
                $unit.Parent = $inventory.Units.get_Item($parentId)
                $unit.Parent.Children.Add($unit)
            }
            if ($textId) { $unit.CorrespondingText = $inventory.Units.get_Item($textId) }
        }
        $inventory
    } finally {
        $reader.Dispose()
    }
}

function Read-StudentFlacClock {
    param([IO.Stream] $Stream)
    $header = [byte[]]::new(42)
    $Stream.ReadExactly($header)
    if ([Text.Encoding]::ASCII.GetString($header,0,4) -cne 'fLaC' -or
        ($header[4] -band 127) -ne 0 -or $header[5] -ne 0 -or $header[6] -ne 0 -or $header[7] -ne 34) {
        throw 'Invalid FLAC STREAMINFO.'
    }
    $clock = [uint64]0
    for ($i=18;$i -lt 26;$i++) { $clock = ($clock -shl 8) -bor $header[$i] }
    [ValueTuple[int,int,long]]::new(($clock -shr 44),((($clock -shr 41) -band 7)+1),($clock -band [uint64]68719476735))
}

Export-ModuleMember -Function Add-StudentSourceFile, Save-StudentSourceInventory, Open-StudentSourceInventory, Read-StudentFlacClock
