param([Parameter(Mandatory)][string]$Text, [string]$OutPrefix)
# Zira capture: PCM at 22050 Hz 16-bit mono, phoneme events with AudioPosition and Duration, word events.
Add-Type -AssemblyName System.Speech
$s = [System.Speech.Synthesis.SpeechSynthesizer]::new()
$s.SelectVoice('Microsoft Zira Desktop')
$fmt = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(22050, 'Sixteen', 'Mono')
$wavePath = $null
if ($OutPrefix) {
    $wavePath = [IO.Path]::GetFullPath("$OutPrefix.wav")
    if (Test-Path -LiteralPath $wavePath) { throw 'Use a new Zira reference WAV path.' }
    $s.SetOutputToWaveFile($wavePath, $fmt)
} else { $s.SetOutputToNull() }
$events = [System.Collections.Generic.List[object]]::new()
$s.add_PhonemeReached({ param($o, $e) $events.Add([pscustomobject]@{ Kind = 'phoneme'; Text = $e.Phoneme; StartMs = $e.AudioPosition.TotalMilliseconds; DurMs = $e.Duration.TotalMilliseconds; Emphasis = [int]$e.Emphasis; Next = $e.NextPhoneme }) })
$s.add_SpeakProgress({ param($o, $e) $events.Add([pscustomobject]@{ Kind = 'word'; Text = $e.Text; StartMs = $e.AudioPosition.TotalMilliseconds; DurMs = 0; Emphasis = 0; Next = '' }) })
try { $s.Speak($Text) } finally { $s.SetOutputToNull(); $s.Dispose() }
$ph = @($events | Where-Object Kind -eq phoneme)
[pscustomobject]@{ Text = $Text; Voice = 'Microsoft Zira Desktop'; SampleRate = 22050; WavePath = $wavePath
    Phonemes = $ph; Words = @($events | Where-Object Kind -eq word)
    PhonemeDurationMs = ($ph | Measure-Object DurMs -Sum).Sum
    AudioPositionEndMs = $(if ($ph.Count) { $ph[-1].StartMs + $ph[-1].DurMs } else { 0 })
    TimingStatus = 'AudioPosition and Duration are separate reported clocks; validate alignment against the WAV before using either as an acoustic target.'
    TeacherStatus = 'Unassessed'; GateReason = 'Admit the observation before learning or scoring; rejected or uncertain evidence supplies no update or student penalty.' }
