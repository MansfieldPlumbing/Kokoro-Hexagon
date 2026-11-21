using module ./StudentSourceInventory.psm1
using module ./StudentNativeSpeech.psm1
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Decoder,
    [Parameter(Mandatory)][string] $Probe,
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank')
)
$ErrorActionPreference='Stop'
$bank=Open-StudentSourceInventory (Join-Path $BankPath 'sources.bin')
$directory=[IO.Directory]::CreateDirectory((Join-Path $BankPath 'native-speech')).FullName
$decoderPath=(Resolve-Path -LiteralPath $Decoder).Path
$decoderHash=(Get-FileHash -LiteralPath $decoderPath).Hash
$watch=[Diagnostics.Stopwatch]::StartNew()
foreach ($source in $bank.Units.Values) {
    if ($source.Kind -cnotin 'OriginalHumanAudio','OriginalConversationChannel','PrivatePerformanceAudio') { continue }
    if ((Get-FileHash -LiteralPath $source.Path).Hash -cne $source.Checksum) { throw 'Audio source checksum changed.' }
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source.Id)))
    $target=Join-Path $directory "$key.bin"
    if (Test-Path -LiteralPath $target) {
        $prior=Open-StudentNativeSpeech $target $bank
        if ($prior.DecoderHash -ceq $decoderHash) { continue }
    }
    $shape=& $Probe -v error -select_streams a:0 -show_entries stream=sample_rate,channels -of csv=p=0 $source.Path
    if ($LASTEXITCODE -or $shape -cnotmatch '^(?<rate>[0-9]+),(?<channels>[0-9]+)$') { throw 'Native stream clock is unavailable.' }
    $rate=[int]$Matches.rate
    $channels=[int]$Matches.channels
    if ($source.SampleRate -gt 0 -and ($source.SampleRate -ne $rate -or $source.Channels -ne $channels)) { throw 'Native stream clock disagrees with source evidence.' }
    $argsInfo=[Diagnostics.ProcessStartInfo]::new($decoderPath)
    $argsInfo.UseShellExecute=$false
    $argsInfo.RedirectStandardOutput=$true
    $argsInfo.RedirectStandardError=$true
    $filter="asettb=1/$rate,asetpts=N,aspectralstats=win_size=2048:overlap=0.5:measure=centroid+flatness+flux+rolloff,astats=metadata=1:reset=1:measure_perchannel=RMS_level:measure_overall=none,ametadata=mode=print:file='pipe\:1'"
    foreach ($arg in '-v','error','-xerror','-nostdin','-i',$source.Path,'-map','0:a:0','-af',$filter,'-f','null','NUL') { $argsInfo.ArgumentList.Add($arg) }
    $stage="$target.$([guid]::NewGuid()).partial"
    $proc=[Diagnostics.Process]::Start($argsInfo)
    try {
        $errors=$proc.StandardError.ReadToEndAsync()
        $w=[IO.BinaryWriter]::new([IO.File]::Open($stage,[IO.FileMode]::CreateNew))
        try {
            $w.Write('StudentNativeSpeech/1')
            $w.Write($source.Id)
            $w.Write($source.Checksum)
            $w.Write($decoderHash)
            $w.Write($rate)
            $w.Write($channels)
            $values=[single[]]::new(5*$channels)
            $frame=-1
            $seen=0
            while ($null -ne ($line=$proc.StandardOutput.ReadLine())) {
                if ($line -cmatch '^frame:\s*(\d+)\s+pts:\s*(-?\d+)') {
                    if ($frame -ge 0) {
                        if ($seen -ne $values.Length) { throw 'Incomplete native frame observations.' }
                        foreach ($value in $values) { $w.Write($value) }
                    }
                    $frame++
                    if ([long]$Matches[1] -ne $frame -or [long]$Matches[2] -ne 1024L*$frame) { throw 'Discontinuous native feature clock.' }
                    $seen=0
                } elseif ($line -cmatch '^lavfi\.(?:aspectralstats|astats)\.(\d+)\.(centroid|flatness|flux|rolloff|RMS_level)=(.+)$') {
                    $channel=[int]$Matches[1]-1
                    $field=@('centroid','flatness','flux','rolloff','RMS_level').IndexOf($Matches[2])
                    $number=$Matches[3]
                    $values[5*$channel+$field]=switch ($number) {
                        '-inf' { [single]::NegativeInfinity }
                        'inf' { [single]::PositiveInfinity }
                        'nan' { [single]::NaN }
                        '-nan' { [single]::NaN }
                        default { [single]::Parse($number,[Globalization.CultureInfo]::InvariantCulture) }
                    }
                    $seen++
                }
            }
            if ($frame -lt 0 -or $seen -ne $values.Length) { throw 'Incomplete final native frame.' }
            foreach ($value in $values) { $w.Write($value) }
            $proc.WaitForExit()
            if ($proc.ExitCode) { throw $errors.GetAwaiter().GetResult() }
            if ($source.SampleCount -gt 0 -and [Math]::Abs(($frame+1)*1024L-$source.SampleCount) -ge 1024) { throw 'Native frame coverage disagrees with the full source clock.' }
        } finally { $w.Dispose() }
        [IO.File]::Move($stage,$target,$true)
        "kind=$($source.Kind) rate=$rate channels=$channels frames=$($frame+1) wallSeconds=$($watch.Elapsed.TotalSeconds)"
    } finally {
        if (!$proc.HasExited) { $proc.Kill() }
        $proc.Dispose()
        [IO.File]::Delete($stage)
    }
}
