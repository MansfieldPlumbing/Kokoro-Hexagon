using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $LexiconModule,
    [string] $InventoryPath = (Join-Path $PSScriptRoot '../data/source-bank/sources.bin'),
    [string] $EvidenceDirectory = (Join-Path $PSScriptRoot '../data/source-bank/linguistic')
)

class StudentLexicalReadings {
    [object[]] $WordForms
    [object] $MobyAssociations
}

class StudentLexicalDocument {
    [StudentTextEvidence] $Document
    [int[]] $OccurrenceReadings
    [StudentLexicalReadings[]] $Readings
}

$ErrorActionPreference = 'Stop'
$inventory = Open-StudentSourceInventory $InventoryPath
$wordnet = $inventory.Units.get_Item('StudentLexicon/english-wordnet-2025-plus.xml.gz')
$moby = $inventory.Units.get_Item('StudentLexicon/mthesaur.txt')
foreach ($unit in $wordnet,$moby) {
    if ((Get-FileHash -LiteralPath $unit.Path).Hash -cne $unit.Checksum) { throw 'Lexical source checksum mismatch.' }
}
$module = Import-Module (Resolve-Path -LiteralPath $LexiconModule).Path -PassThru
$corpus = & $module {
    param($WordNetPath, $MobyPath)
    $loaded = [StudentLexicalCorpus]::new()
    $loaded.ReadWordNetGzip($WordNetPath)
    $loaded.ReadMoby($MobyPath)
    $loaded
} $wordnet.Path $moby.Path
if ($corpus.GetType().Name -cne 'StudentLexicalCorpus') { throw 'Expected the existing typed lexical importer.' }

$bySpelling = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::OrdinalIgnoreCase)
$pool = [Collections.Generic.List[StudentLexicalReadings]]::new()
$documents = [Collections.Generic.List[StudentLexicalDocument]]::new()
foreach ($file in Get-ChildItem -LiteralPath $EvidenceDirectory -Filter 'pg*.bin' -File) {
    $doc = Open-StudentTextEvidence $file.FullName $inventory
    if ((Get-FileHash -LiteralPath $doc.Source.Path).Hash -cne $doc.Source.Checksum) { throw 'Original text has changed.' }
    $text = [IO.File]::ReadAllText($doc.Source.Path)
    $joined = [StudentLexicalDocument]::new()
    $joined.Document = $doc
    $joined.OccurrenceReadings = [int[]]::new($doc.Tokens.Length / 4)
    [Array]::Fill($joined.OccurrenceReadings,-1)
    for ($i = 0; $i -lt $joined.OccurrenceReadings.Length; $i++) {
        if ($doc.Tokens[4*$i] -ne 1 -or $doc.OriginalSpans[2*$i] -lt 0) { continue }
        $spelling = $text.Substring($doc.OriginalSpans[2*$i],$doc.OriginalSpans[2*$i+1]).ToLowerInvariant()
        $index = 0
        if (!$bySpelling.TryGetValue($spelling,[ref]$index)) {
            $forms = $corpus.FindForms($spelling)
            $related = $corpus.FindRelated($spelling)
            $index = -1
            if ($forms.Length -or $null -ne $related) {
                $index = $pool.Count
                $readings = [StudentLexicalReadings]::new()
                $readings.WordForms = $forms
                $readings.MobyAssociations = $related
                $pool.Add($readings)
            }
            $bySpelling.Add($spelling,$index)
        }
        $joined.OccurrenceReadings[$i] = $index
    }
    $documents.Add($joined)
}

$shared = $pool.ToArray()
foreach ($joined in $documents) {
    $joined.Readings = $shared
    $joined
}
