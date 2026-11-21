using module ./StudentSourceInventory.psm1
#requires -Version 7.4

class StudentTextEvidence {
    [StudentSourceUnit] $Source
    [string] $DriverHash
    [string] $KernelHash
    [int[]] $Tokens
    [int[]] $OriginalSpans
    [int[]] $Paragraphs
    [int[]] $Sentences
    [bool[]] $Headings
    [bool[]] $CounterExamples
    [StudentSentenceEvidence[]] $Interpretations
    [StudentTextIssue[]] $Issues
}

class StudentTextIssue {
    [StudentTextEvidence] $Document
    [int] $Start
    [int] $Length
    [string] $Status
}

class StudentSentenceEvidence {
    [StudentTextEvidence] $Document
    [int] $Index
    [string] $Grammar
    [string] $Pronunciation
    [string] $Failure
    [string] $Phones
    [int[]] $OccurrenceRanges
    [string[]] $Readings
    [string[]] $ProducingSources
    [string[]] $Statuses
    [int[][]] $Roles
    [string[][]] $Alternatives
    [StudentMorphologyEvidence[]] $Morphology
    [StudentGrammarEvidence[]] $Relations
}

class StudentGrammarEvidence {
    [StudentSentenceEvidence] $Sentence
    [string] $Kind
    [int[]] $Occurrences
    [int] $Support
    [int] $Viable
}

class StudentMorphologyEvidence {
    [StudentSentenceEvidence] $Sentence
    [int] $Occurrence
    [int] $Role
    [int] $RootId
    [string] $Root
    [string] $Phones
    [string[]] $Rules
}

function Read-StudentVector($Reader, [type] $Type, [string] $Method) {
    $size = $Reader.ReadInt32()
    if ($size -lt 0 -or $size -gt $Reader.BaseStream.Length - $Reader.BaseStream.Position) {
        throw 'Invalid text evidence vector extent.'
    }
    $values = [Array]::CreateInstance($Type, $size)
    if ($Type -in [int], [bool]) {
        $byteCount = [Buffer]::ByteLength($values)
        if ($byteCount -gt $Reader.BaseStream.Length - $Reader.BaseStream.Position) { throw 'Truncated text evidence vector.' }
        $bytes = $Reader.ReadBytes($byteCount)
        [Buffer]::BlockCopy($bytes,0,$values,0,$bytes.Length)
    } else {
        for ($j = 0; $j -lt $size; $j++) { $values[$j] = $Reader.$Method() }
    }
    ,$values
}

function Open-StudentTextEvidence {
    param([string] $Path, [StudentSourceInventory] $Inventory)
    $r = [IO.BinaryReader]::new([IO.File]::OpenRead((Convert-Path -LiteralPath $Path)))
    try {
        $version = $r.ReadString()
        if ($version -cnotin 'StudentTextEvidence/1','StudentTextEvidence/2') { throw 'Unknown text evidence format.' }
        $doc = [StudentTextEvidence]::new()
        $doc.Source = $Inventory.Units.get_Item($r.ReadString())
        $doc.DriverHash = $r.ReadString()
        $doc.KernelHash = $r.ReadString()
        $doc.Issues = [StudentTextIssue[]]::new(0)
        if ($version -ceq 'StudentTextEvidence/2') {
            $doc.Issues = [StudentTextIssue[]]::new($r.ReadInt32())
            for ($i=0;$i -lt $doc.Issues.Length;$i++) {
                $issue = [StudentTextIssue]::new()
                $issue.Document = $doc
                $issue.Start = $r.ReadInt32()
                $issue.Length = $r.ReadInt32()
                $issue.Status = $r.ReadString()
                $doc.Issues[$i] = $issue
            }
        }
        foreach ($property in 'Tokens','OriginalSpans','Paragraphs','Sentences') {
            $doc.$property = Read-StudentVector $r ([int]) ReadInt32
        }
        foreach ($property in 'Headings','CounterExamples') { $doc.$property = Read-StudentVector $r ([bool]) ReadBoolean }
        $doc.Interpretations = [StudentSentenceEvidence[]]::new($r.ReadInt32())
        for ($i = 0; $i -lt $doc.Interpretations.Count; $i++) {
            $sentence = [StudentSentenceEvidence]::new()
            $sentence.Document = $doc
            $sentence.Index = $i
            foreach ($field in 'Grammar','Pronunciation','Failure','Phones') { $sentence.$field = $r.ReadString() }
            $sentence.OccurrenceRanges = Read-StudentVector $r ([int]) ReadInt32
            foreach ($field in 'Readings','ProducingSources','Statuses') { $sentence.$field = Read-StudentVector $r ([string]) ReadString }
            if ($version -ceq 'StudentTextEvidence/2') {
                $sentence.Roles = [int[][]]::new($sentence.Readings.Length)
                $sentence.Alternatives = [string[][]]::new($sentence.Readings.Length)
                for ($t=0; $t -lt $sentence.Readings.Length; $t++) {
                    $sentence.Roles[$t] = Read-StudentVector $r ([int]) ReadInt32
                    $sentence.Alternatives[$t] = Read-StudentVector $r ([string]) ReadString
                }
            }
            $sentence.Morphology = [StudentMorphologyEvidence[]]::new($r.ReadInt32())
            for ($m = 0; $m -lt $sentence.Morphology.Length; $m++) {
                $reading = [StudentMorphologyEvidence]::new()
                $reading.Sentence = $sentence
                $reading.Occurrence = $r.ReadInt32()
                $reading.Role = $r.ReadInt32()
                $reading.RootId = $r.ReadInt32()
                $reading.Root = $r.ReadString()
                $reading.Phones = $r.ReadString()
                $reading.Rules = Read-StudentVector $r ([string]) ReadString
                $sentence.Morphology[$m] = $reading
            }
            $sentence.Relations = [StudentGrammarEvidence[]]::new($r.ReadInt32())
            for ($m = 0; $m -lt $sentence.Relations.Length; $m++) {
                $relation = [StudentGrammarEvidence]::new()
                $relation.Sentence = $sentence
                $relation.Kind = $r.ReadString()
                $relation.Support = $r.ReadInt32()
                $relation.Viable = $r.ReadInt32()
                $relation.Occurrences = Read-StudentVector $r ([int]) ReadInt32
                $sentence.Relations[$m] = $relation
            }
            $doc.Interpretations[$i] = $sentence
        }
        if ($r.BaseStream.Position -ne $r.BaseStream.Length) { throw 'Trailing text evidence data.' }
        $doc
    } finally { $r.Dispose() }
}

Export-ModuleMember -Function Open-StudentTextEvidence
