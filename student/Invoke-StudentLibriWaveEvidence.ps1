#requires -Version 7.7
param(
    [Parameter(Mandatory)][string] $Decoder,
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank')
)
$ErrorActionPreference='Stop'
$libriRoot=[IO.Directory]::CreateDirectory((Join-Path $BankPath 'libri-native')).FullName
$extract=Join-Path $libriRoot 'decode-input'
$decoderPath=(Resolve-Path -LiteralPath $Decoder).Path
$decoderHash=(Get-FileHash -LiteralPath $decoderPath).Hash
$watch=[Diagnostics.Stopwatch]::StartNew()
$libri=@(& "$PSScriptRoot/Open-StudentLibriSpeech.ps1" -InventoryPath (Join-Path $BankPath 'sources.bin') -ExtractAudioDirectory $extract)
$null=. "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition
$kernels=& $studentOwner { Import-StudentKernels }
$measured=0
foreach ($chapter in $libri) {
    if ($chapter.GetType().Name -cne 'StudentLibriChapter') { continue }
    $target=Join-Path $libriRoot "$($chapter.Chapter).bin"
    if (Test-Path -LiteralPath $target) {
        $prior=[IO.BinaryReader]::new([IO.File]::OpenRead($target))
        try {
            if ($prior.ReadString() -ceq 'StudentLibriNativeRms/1' -and $prior.ReadString() -ceq $chapter.Archive.Checksum -and
                $prior.ReadString() -ceq $kernels.SHA256 -and $prior.ReadString() -ceq $decoderHash) { continue }
        } finally { $prior.Dispose() }
    }
    $temporary="$target.$([guid]::NewGuid()).partial"
    $concat="$temporary.ffconcat"
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('ffconcat version 1.0')
    $rate=$chapter.Utterances[0].Rate
    foreach ($utterance in $chapter.Utterances) {
        if ($utterance.Rate -ne $rate) { throw 'Chapter has multiple native rates.' }
        $path=(Join-Path $extract ($utterance.Id+'.flac')).Replace('\','/').Replace("'","'\''")
        $lines.Add("file '$path'")
    }
    [IO.File]::WriteAllLines($concat,$lines,[Text.UTF8Encoding]::new($false))
    $start=[Diagnostics.ProcessStartInfo]::new($decoderPath)
    $start.UseShellExecute=$false
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach ($arg in '-v','error','-xerror','-nostdin','-f','concat','-safe','0','-i',$concat,'-map','0:a:0','-f','s16le','pipe:1'){
        $start.ArgumentList.Add($arg)
    }
    try {
        $process=[Diagnostics.Process]::Start($start)
        try {
            $errors=$process.StandardError.ReadToEndAsync()
            $out=$process.StandardOutput.BaseStream
            $writer=[IO.BinaryWriter]::new([IO.File]::Open($temporary,[IO.FileMode]::CreateNew))
            try {
                $writer.Write('StudentLibriNativeRms/1')
                $writer.Write($chapter.Archive.Checksum)
                $writer.Write($kernels.SHA256)
                $writer.Write($decoderHash)
                $hop=[int]($rate/50)
                foreach ($utterance in $chapter.Utterances) {
                    $bytes=[byte[]]::new(2*$utterance.Samples)
                    $out.ReadExactly($bytes)
                    $signal=$kernels.MonoPcm16.Invoke($bytes,0,$utterance.Samples)
                    $rms=$kernels.FrameLevels.Invoke($signal,$hop)
                    $writer.Write($utterance.Id)
                    $writer.Write($utterance.AudioHash)
                    $writer.Write($hop)
                    $writer.Write([int]$rms.Length)
                    $levels=[byte[]]::new(4*$rms.Length)
                    [Buffer]::BlockCopy($rms,0,$levels,0,$levels.Length)
                    $writer.Write($levels)
                    $measured++
                }
                if ($out.ReadByte() -ne -1) { throw 'Decoded output exceeds native utterance clocks.' }
                $process.WaitForExit()
                if ($process.ExitCode) { throw $errors.GetAwaiter().GetResult() }
            } finally { $writer.Dispose() }
        } finally {
            if (!$process.HasExited) { $process.Kill() }
            $process.Dispose()
        }
        [IO.File]::Move($temporary,$target,$true)
    } finally { [IO.File]::Delete($temporary); [IO.File]::Delete($concat) }
}
"utterancesMeasured=$measured elapsed=$($watch.Elapsed.TotalSeconds)"
