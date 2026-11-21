using module ./StudentSourceInventory.psm1
#requires -Version 7.7
param(
    [Parameter(Mandatory)][string] $Decoder,
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank'),
    [ValidateRange(1,[int]::MaxValue)][int] $ShardCount=1,
    [ValidateRange(0,[int]::MaxValue)][int] $ShardIndex=0
)
$ErrorActionPreference='Stop'
$bank=Open-StudentSourceInventory (Join-Path $BankPath 'sources.bin')
$directory=[IO.Directory]::CreateDirectory((Join-Path $BankPath 'human-dictation')).FullName
$decoderHash=(Get-FileHash -LiteralPath $Decoder).Hash
$speechLibrary=Join-Path $PSHOME 'System.Speech.dll'
Add-Type -Path $speechLibrary
$assemblyHash=(Get-FileHash -LiteralPath $speechLibrary).Hash
$clock=[Diagnostics.Stopwatch]::StartNew()
if ($ShardIndex -ge $ShardCount) { throw 'Shard index lies outside the requested workers.' }
$sources=@($bank.Units.Values | Where-Object Kind -CEQ OriginalHumanAudio | Sort-Object Id)
for ($index=$ShardIndex;$index -lt $sources.Count;$index+=$ShardCount) {
    $source=$sources[$index]
    if ((Get-FileHash -LiteralPath $source.Path).Hash -cne $source.Checksum) { throw 'Human source checksum mismatch.' }
    $name=[IO.Path]::GetFileNameWithoutExtension($source.Path)
    $target=Join-Path $directory "$name.full.bin"
    if (Test-Path -LiteralPath $target) { continue }
    $temp=Join-Path $directory ([guid]::NewGuid().ToString())
    $wav="$temp.wav"
    $stage="$temp.partial"
    try {
        & $Decoder -v error -xerror -nostdin -i $source.Path -map 0:a:0 -ac 1 -ar 16000 $wav
        if ($LASTEXITCODE) { throw 'Dictation input decode failed.' }
        $engine=[System.Speech.Recognition.SpeechRecognitionEngine]::new([Globalization.CultureInfo]'en-US')
        try {
            $engine.LoadGrammar([System.Speech.Recognition.DictationGrammar]::new())
            $engine.SetInputToWaveFile($wav)
            $w=[IO.BinaryWriter]::new([IO.File]::Open($stage,[IO.FileMode]::CreateNew))
            $words=0
            try {
                $w.Write('StudentHumanDictation/3')
                $w.Write($source.Id)
                $w.Write($source.Checksum)
                $w.Write($decoderHash)
                $w.Write($assemblyHash)
                $w.Write($engine.RecognizerInfo.Id)
                $events=@("$temp-word","$temp-complete")
                try {
                    $null=Register-ObjectEvent $engine SpeechRecognized -SourceIdentifier $events[0]
                    $null=Register-ObjectEvent $engine RecognizeCompleted -SourceIdentifier $events[1]
                    $engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
                    while ($true) {
                        $event=Wait-Event -Timeout 5
                        if (!$event) { continue }
                        if ($event.SourceIdentifier -cnotin $events) { throw 'Unexpected event in the dictation worker.' }
                        Remove-Event -EventIdentifier $event.EventIdentifier
                        if ($event.SourceIdentifier -ceq $events[1]) {
                            if ($event.SourceEventArgs.Error) { throw $event.SourceEventArgs.Error }
                            if (!$event.SourceEventArgs.InputStreamEnded) { throw 'Recognizer did not consume the complete recording.' }
                            break
                        }
                        $result=$event.SourceEventArgs.Result
                        $w.Write([long]$result.Audio.AudioPosition.Ticks)
                        $w.Write([long]$result.Audio.Duration.Ticks)
                        $w.Write([int]$result.Words.Count)
                        foreach ($word in $result.Words) {
                            $w.Write([string]$word.Text)
                            $w.Write([string]($word.Pronunciation ?? ''))
                            $w.Write([single]$word.Confidence)
                            $words++
                        }
                    }
                } finally {
                    foreach ($id in $events) {
                        Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
                        Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue | Remove-Event
                    }
                }
            } finally { $w.Dispose() }
        } finally { $engine.Dispose() }
        [IO.File]::Move($stage,$target)
        "recording=$name wordHypotheses=$words elapsed=$($clock.Elapsed.TotalSeconds)"
    } catch { Write-Warning "$name : $($_.Exception.Message)" }
    finally { [IO.File]::Delete($wav); [IO.File]::Delete($stage) }
}
