using module ./StudentSourceInventory.psm1
#requires -Version 7.7

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InventoryPath,
    [Parameter(Mandatory)][string] $SpanId,
    [Parameter(Mandatory)][string] $PhonemizerReceipt,
    [Parameter(Mandatory)][string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$pairInventory = Open-StudentSourceInventory $InventoryPath
$pairSpan = $pairInventory.Units.get_Item($SpanId)
if ($pairSpan.Kind -cne 'TextSpanUtf16') { throw 'Select a UTF-16 text span in the source inventory.' }
$pairWork = $pairSpan.Parent
if ((Get-FileHash -LiteralPath $pairWork.Path).Hash -cne $pairWork.Checksum) { throw 'Original source checksum mismatch.' }
$pairSource = [IO.File]::ReadAllText($pairWork.Path, [Text.UTF8Encoding]::new($false, $true))
$pairText = $pairSource.Substring($pairSpan.Start, $pairSpan.Length) -replace '\r\n|\n|\r', ' '
$pairDirectory = [IO.Directory]::CreateDirectory($OutputDirectory).FullName
$pairReceipt = Get-Item -LiteralPath $PhonemizerReceipt
$ziraPath = Join-Path $pairDirectory 'zira.wav'
$kokoroPath = Join-Path $pairDirectory 'kokoro.wav'
$ziraEvents = Join-Path $pairDirectory 'zira-events.psd1'
$kokoroControls = Join-Path $pairDirectory 'kokoro-controls.bin'
$pairIndex = Join-Path $pairDirectory 'sources.bin'
foreach ($path in $ziraPath, $kokoroPath, $ziraEvents, $kokoroControls, $pairIndex) {
    if (Test-Path -LiteralPath $path) { throw 'Select an output directory for a new teacher pair.' }
}

$null = . "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition
& $studentOwner {
    param($inputText, $receipt, $targetZira, $targetKokoro, $targetEvents, $targetControls)
    $zira = Import-StudentZira
    $pin = Import-PowerShellDataFile $receipt.FullName
    $script:StudentInputs.Phonemizer = @{
        Directory = [IO.Path]::GetRelativePath($script:StudentRoot, $receipt.DirectoryName)
        SHA256 = $pin.AssemblySha256
    }
    $syllabusDirectory = Join-Path $script:StudentBuild ('student/teacher-pair-' + [guid]::NewGuid())
    $syllabus = Import-StudentSyllabus $syllabusDirectory
    try {
        $spoken = New-StudentTextPhones $inputText
        if (!$spoken.Phonemes) { throw 'Student phonemizer returned an empty utterance.' }
        & $zira {
            param($utterance, $wave, $events)
            $capture = Get-EnglishZiraReference -Text $utterance -NoSave -WavePath $wave
            if ((Get-FileHash -LiteralPath $wave).Hash -cne $capture.WaveSHA256) {
                throw 'Zira WAV and events came from different captures.'
            }
            [IO.File]::WriteAllText($events, (Save-EnglishZiraObservation -Capture $capture -SourceOnly))
            $restored = Import-EnglishZiraObservation -Path $events
            if ($restored.Identity -cne $capture.Identity -or $restored.Phones.Count -ne $capture.Phones.Count -or
                $restored.Words.Count -ne $capture.Words.Count) { throw 'Zira event reload failed.' }
        } $inputText $targetZira $targetEvents
        $speech = & $syllabus {
            param($phones)
            Invoke-OfflineSpeech -Phonemes $phones -Voice af_heart
        } $spoken.Phonemes
        [IO.File]::WriteAllBytes($targetKokoro, (ConvertTo-StudentWave $speech.Pcm))
        $writer = [IO.BinaryWriter]::new([IO.File]::Open($targetControls, [IO.FileMode]::CreateNew))
        try {
            $writer.Write('KokoroTeacherControls')
            $writer.Write([int]1)
            $writer.Write([string]$inputText)
            $writer.Write([string]$speech.Phonemes)
            $writer.Write([string]$speech.Voice)
            $writer.Write([long]$speech.Seed)
            $writer.Write([string]$pin.AssemblySha256)
            $writer.Write((Get-FileHash -LiteralPath $targetKokoro).Hash)
            foreach ($array in $speech.TokenIds, $speech.Durations, $speech.F0, $speech.N) {
                $writer.Write([int]$array.Length)
                foreach ($value in $array) {
                    if ($array -is [float[]]) { $writer.Write([float]$value) }
                    else { $writer.Write([int]$value) }
                }
            }
        } finally {
            $writer.Dispose()
        }
    } finally {
        Remove-Module -ModuleInfo $syllabus -Force
        Remove-Module -ModuleInfo $zira -Force
    }
} $pairText $pairReceipt $ziraPath $kokoroPath $ziraEvents $kokoroControls

$pairGraph = [StudentSourceInventory]::new()
# Copies limit the pair index to this work, this span and its rendered audio.
$pairWork = Add-StudentSourceFile -Inventory $pairGraph -Id $pairWork.Id -Kind $pairWork.Kind -Path $pairWork.Path `
    -PublisherUri $pairWork.PublisherUri -Rights $pairWork.Rights -EvidenceGroup $pairWork.EvidenceGroup
$sourceSpan = [StudentSourceUnit]::new()
$sourceSpan.Id = $pairSpan.Id
$sourceSpan.Kind = $pairSpan.Kind
$sourceSpan.Start = $pairSpan.Start
$sourceSpan.Length = $pairSpan.Length
$sourceSpan.Parent = $pairWork
$pairGraph.Add($sourceSpan)
$ziraAudio = Add-StudentSourceFile -Inventory $pairGraph -Id "$($sourceSpan.Id)/MicrosoftZiraDesktop" -Kind TeacherAudio `
    -Path $ziraPath -EvidenceGroup 'MicrosoftZiraDesktop' -Parent $sourceSpan -CorrespondingText $sourceSpan
$kokoroAudio = Add-StudentSourceFile -Inventory $pairGraph -Id "$($sourceSpan.Id)/Kokoro-af_heart" -Kind TeacherAudio `
    -Path $kokoroPath -EvidenceGroup 'Kokoro-af_heart' -Parent $sourceSpan -CorrespondingText $sourceSpan
$null = Add-StudentSourceFile -Inventory $pairGraph -Id "$($ziraAudio.Id)/events" -Kind TeacherReportedEvents `
    -Path $ziraEvents -EvidenceGroup $ziraAudio.EvidenceGroup -Parent $ziraAudio -CorrespondingText $sourceSpan
$null = Add-StudentSourceFile -Inventory $pairGraph -Id "$($kokoroAudio.Id)/controls" -Kind TeacherPredictorControls `
    -Path $kokoroControls -EvidenceGroup $kokoroAudio.EvidenceGroup -Parent $kokoroAudio -CorrespondingText $sourceSpan
Save-StudentSourceInventory $pairGraph $pairIndex
$pairGraph
