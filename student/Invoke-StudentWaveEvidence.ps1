using module ./StudentSourceInventory.psm1
#requires -Version 7.7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Decoder,
    [string] $InventoryPath=(Join-Path $PSScriptRoot '../data/source-bank/sources.bin'),
    [string] $EvidenceDirectory=(Join-Path $PSScriptRoot '../data/source-bank/waveform')
)
$ErrorActionPreference='Stop'
$bank=Open-StudentSourceInventory $InventoryPath
$destination=[IO.Directory]::CreateDirectory($EvidenceDirectory).FullName
$decoderPath=(Resolve-Path -LiteralPath $Decoder).Path
$decoderHash=(Get-FileHash -LiteralPath $decoderPath).Hash
$null=. "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition
$kernels=& $studentOwner { Import-StudentKernels }
$clock=[Diagnostics.Stopwatch]::StartNew()
$rate=8000
$hop=160
$window=320
$sources=$bank.Units.Values.Where({$_.Kind -cin 'OriginalHumanAudio','OriginalConversationChannel','PrivatePerformanceAudio'})
foreach ($source in $sources) {
    if ((Get-FileHash -LiteralPath $source.Path).Hash -cne $source.Checksum) { throw 'Waveform source checksum differs from the bank.' }
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source.Id)))
    $target=Join-Path $destination "$key.bin"
    $stage="$target.$([guid]::NewGuid()).partial"
    $settings=[Diagnostics.ProcessStartInfo]::new($decoderPath)
    $settings.UseShellExecute=$false
    $settings.RedirectStandardOutput=$true
    $settings.RedirectStandardError=$true
    foreach ($arg in '-v','error','-xerror','-nostdin','-i',$source.Path,'-map','0:a:0','-ac','1','-ar',[string]$rate,'-f','s16le','pipe:1') {
        $settings.ArgumentList.Add($arg)
    }
    $process=[Diagnostics.Process]::Start($settings)
    $pcm=[IO.MemoryStream]::new()
    try {
        $errors=$process.StandardError.ReadToEndAsync()
        $process.StandardOutput.BaseStream.CopyTo($pcm)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or !$pcm.Length -or $pcm.Length % 2) {
            throw "Waveform decode failed for $($source.Id): $($errors.GetAwaiter().GetResult())"
        }
        $samples=[int]($pcm.Length/2)
        $signal=$kernels.MonoPcm16.Invoke($pcm.GetBuffer(),0,$samples)
    } finally { $pcm.Dispose(); $process.Dispose() }
    if ($source.SampleRate -gt 0 -and [Math]::Abs($source.SampleCount*[double]$rate/$source.SampleRate-$samples) -ge 1) {
        throw "Resampled duration differs from source clock for $($source.Id)"
    }
    $rms=$kernels.FrameLevels.Invoke($signal,$hop)
    $pitch=$kernels.PitchTrack.Invoke($signal,$rate,$hop,$window,12,160,0.15)
    $signal=$null
    $waveLabels=[Collections.Generic.List[StudentSourceUnit]]::new()
    if ($source.Kind -ceq 'OriginalConversationChannel') {
        foreach ($child in $source.Children) {
            if ($child.Kind -cin 'PublisherTranscriptWordSamples','PublisherTranscriptEventSamples') {
                $waveLabels.Add($child)
            }
        }
    }
    try {
        $writer=[IO.BinaryWriter]::new([IO.File]::Open($stage,[IO.FileMode]::CreateNew))
        try {
            $writer.Write('StudentWaveEvidence/1')
            $writer.Write($source.Id)
            $writer.Write($kernels.SHA256)
            $writer.Write($decoderHash)
            $writer.Write([int]$rate)
            $writer.Write([int]$hop)
            $writer.Write([int]$window)
            $writer.Write([long]$samples)
            foreach ($array in $rms,$pitch) {
                $bytes=[byte[]]::new(4*$array.Length)
                [Buffer]::BlockCopy($array,0,$bytes,0,$bytes.Length)
                $writer.Write([int]$array.Length)
                $writer.Write($bytes)
            }
            $writer.Write([int]$waveLabels.Count)
            foreach ($label in $waveLabels) {
                if ($source.SampleRate -le 0 -or $hop -le 0) {
                    throw "Invalid annotation clock for $($source.Id), rate $($source.SampleRate), hop $hop."
                }
                $first=[int][Math]::Ceiling($label.Start*[double]$rate/($source.SampleRate*$hop))
                $end=[int][Math]::Min($rms.Length,[Math]::Floor(($label.Start+$label.Length)*[double]$rate/($source.SampleRate*$hop)))
                $power=0.0
                $f0=0.0
                $voiced=0
                for ($index=$first;$index -lt $end;$index++) {
                    $power+=[double]$rms[$index]*$rms[$index]
                    if (3*$index -lt $pitch.Length -and $pitch[3*$index] -gt 0) {
                        $f0+=$pitch[3*$index]
                        $voiced++
                    }
                }
                $count=[Math]::Max(0,$end-$first)
                $writer.Write($label.Id)
                $writer.Write([float]$(if($count){[Math]::Sqrt($power/$count)}else{[float]::NaN}))
                $writer.Write([float]$(if($voiced){$f0/$voiced}else{[float]::NaN}))
                $writer.Write([int]$count)
            }
        } finally { $writer.Dispose() }
        [IO.File]::Move($stage,$target,$true)
    } finally { [IO.File]::Delete($stage) }
    "kind=$($source.Kind) file=$key seconds=$($samples/$rate) frames=$($rms.Length) pitchFrames=$($pitch.Length/3) annotationComparisons=$($waveLabels.Count) elapsed=$($clock.Elapsed.TotalSeconds)"
}
