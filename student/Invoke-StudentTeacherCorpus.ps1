using module ./StudentSourceInventory.psm1
using module ./StudentTextEvidence.psm1
using module ./StudentTeacherObservation.psm1
#requires -Version 7.7
param(
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank'),
    [ValidateRange(0,[int]::MaxValue)][int] $NewPerWork=0,
    [string] $WorkIdentity,
    [int[]] $SentenceIndex
)
$ErrorActionPreference='Stop'
if ($SentenceIndex -and !$WorkIdentity) { throw 'Selected sentence ordinals require an explicit work identity.' }
$bank=Open-StudentSourceInventory (Join-Path $BankPath 'sources.bin')
$bankRoot=(Resolve-Path -LiteralPath $BankPath).Path
$teacherRoot=[IO.Directory]::CreateDirectory((Join-Path $bankRoot 'paired-teachers')).FullName
$watch=[Diagnostics.Stopwatch]::StartNew()
$null=. "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition -Threads 4
& $studentOwner {
    param($inventory,$bankRoot,$teacherRoot,$budget,$watch,$workIdentity,$sentenceIndex)
    $zira=Import-StudentZira
    $syllabus=Import-StudentSyllabus (Join-Path $script:StudentBuild ('student/paired-teachers-'+[guid]::NewGuid()))
    try {
        $paths=@($script:StudentInputs.Syllabus,$script:StudentInputs.Manifest,$script:StudentInputs.Pronunciation,'tools/Kokoro.TextEncoder.psm1','student/Invoke-StudentTeacherCorpus.ps1')
        $engine=Join-Path $env:WINDIR 'System32/speech/engines/tts/MSTTSEngine.dll'
        $hashes=@($paths | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $script:StudentRoot $_)).Hash })
        $hashes+=(Get-FileHash -LiteralPath $engine).Hash
        for ($index=0;$index -lt $paths.Count;$index++) {
            $sourcePath=Join-Path $script:StudentRoot $paths[$index]
            $pinDirectory=[IO.Directory]::CreateDirectory((Join-Path $bankRoot "teacher-provenance/$($hashes[$index])")).FullName
            $pinned=Join-Path $pinDirectory ([IO.Path]::GetFileName($sourcePath))
            if (!(Test-Path -LiteralPath $pinned)) { [IO.File]::Copy($sourcePath,$pinned) }
            if ((Get-FileHash -LiteralPath $pinned).Hash -cne $hashes[$index]) { throw 'Teacher runtime pin mismatch.' }
        }
        $configuration="af_heart; speed=1; threads=4; PowerShell=$($PSVersionTable.PSVersion); CLR=$([Environment]::Version); SHA256=$($hashes -join ',')"
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $bankRoot 'linguistic') -File -Filter 'pg*.bin') {
            $doc=Open-StudentTextEvidence $file.FullName $inventory
            if ($workIdentity -and $doc.Source.EvidenceGroup -cne $workIdentity) { continue }
            if (!$doc.Interpretations.Count) { continue }
            foreach ($index in $sentenceIndex) {
                if ($index -lt 0 -or $index -ge $doc.Interpretations.Count) { throw "Sentence $index is outside the requested work." }
            }
            if ((Get-FileHash -LiteralPath $doc.Source.Path).Hash -cne $doc.Source.Checksum) { throw 'Source text changed.' }
            $original=[IO.File]::ReadAllText($doc.Source.Path)
            $made=0
            for ($i=0;$i -lt $doc.Interpretations.Length;$i++) {
                if ($budget -and $made -ge $budget) { break }
                if ($sentenceIndex -and $i -notin $sentenceIndex) { continue }
                $sentence=$doc.Interpretations[$i]
                if ($sentence.Failure -or !$sentence.Phones -or $sentence.Phones.Length -gt 510) { continue }
                $first=$doc.Sentences[2*$i]
                $last=$doc.Sentences[2*$i+1]
                $from=$doc.OriginalSpans[2*$first]
                $to=$doc.OriginalSpans[2*$last]+$doc.OriginalSpans[2*$last+1]
                if ($from -lt 0 -or $to -le $from -or $to -gt $original.Length) { throw 'Invalid original sentence extent.' }
                $inputText=$original.Substring($from,$to-$from) -replace '\r\n|\r|\n',' '
                if ($inputText.Length -gt 8192) { continue }
                $pin="$configuration; driver=$($doc.DriverHash); kernel=$($doc.KernelHash)"
                $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$($doc.Source.Id)|$i|$pin|$inputText|$($sentence.Phones)")))
                $target=Join-Path $teacherRoot $key
                if (Test-Path -LiteralPath $target) {
                    $null=Open-StudentTeacherObservation $target $doc
                    continue
                }
                $stage=[IO.Directory]::CreateDirectory("$target.$([guid]::NewGuid()).partial").FullName
                try {
                    $ziraWave=Join-Path $stage 'zira.wav'
                    $events=Join-Path $stage 'zira-events.psd1'
                    & $zira {
                        param($words,$wav,$eventPath)
                        if (Test-Path -LiteralPath $wav) { [IO.File]::Delete($wav) }
                        $capture=Get-EnglishZiraReference -Text $words -NoSave -WavePath $wav
                        [IO.File]::WriteAllText($eventPath,(Save-EnglishZiraObservation -Capture $capture -SourceOnly))
                    } $inputText $ziraWave $events
                    $speech=& $syllabus {param($p) Invoke-OfflineSpeech -Phonemes $p -Voice af_heart -RecomputeText} $sentence.Phones
                    $kokoroWave=Join-Path $stage 'kokoro.wav'
                    [IO.File]::WriteAllBytes($kokoroWave,(ConvertTo-StudentWave $speech.Pcm))
                    $w=[IO.BinaryWriter]::new([IO.File]::Open((Join-Path $stage 'observation.bin'),[IO.FileMode]::Create))
                    try {
                        $w.Write('StudentTeacherObservation/1')
                        $w.Write($doc.Source.Id)
                        $w.Write("$pin; seed=$($speech.Seed); text normalization=original line breaks replaced by spaces for Zira, retained Student corpus phones for Kokoro")
                        $w.Write([int]$from)
                        $w.Write([int]($to-$from))
                        $w.Write($inputText)
                        $w.Write($sentence.Phones)
                        $w.Write([long]$speech.Pcm.Length)
                        $w.Write([int]$i)
                        $w.Write([int]$i)
                        foreach ($path in $kokoroWave,$ziraWave,$events) { $w.Write((Get-FileHash -LiteralPath $path).Hash) }
                        $fields='TokenIds','Durations','F0','N','Bert','BertEncoder','DurationFeatures','TextEncoding','Aligned','AcousticStyle','ProsodyStyle','Features'
                        $w.Write([int]$fields.Count)
                        foreach ($field in $fields) {
                            $values=$speech.$field
                            if ($values -isnot [int[]] -and $values -isnot [single[]]) { throw "Missing typed stock observation $field." }
                            $w.Write($field)
                            $w.Write($values -is [int[]])
                            $bytes=[byte[]]::new([Buffer]::ByteLength($values))
                            [Buffer]::BlockCopy($values,0,$bytes,0,$bytes.Length)
                            $w.Write([int]$values.Length)
                            $w.Write($bytes)
                        }
                    } finally { $w.Dispose() }
                    [IO.Directory]::Move($stage,$target)
                    $made++
                    "source=$($doc.Source.EvidenceGroup) sentence=$i samples=$($speech.Pcm.Length) wallSeconds=$($watch.Elapsed.TotalSeconds)"
                } catch {
                    Write-Warning "Teacher pair unresolved for $($doc.Source.EvidenceGroup) sentence ${i}: $($_.Exception.Message)"
                    [IO.File]::WriteAllText((Join-Path $stage 'failure.txt'),$_.Exception.Message)
                    continue
                }
            }
        }
    } finally {
        Remove-Module -ModuleInfo $syllabus -Force
        Remove-Module -ModuleInfo $zira -Force
    }
} $bank $bankRoot $teacherRoot $NewPerWork $watch $WorkIdentity $SentenceIndex
