param([string]$Text, [string]$OutPrefix)
# Zira capture: PCM at 22050 Hz 16-bit mono, phoneme events with AudioPosition and Duration, word events.
Add-Type -AssemblyName System.Speech
$s = [System.Speech.Synthesis.SpeechSynthesizer]::new()
$s.SelectVoice('Microsoft Zira Desktop')
$fmt = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(22050, 'Sixteen', 'Mono')
$s.SetOutputToWaveFile("$OutPrefix.wav", $fmt)
$events = [System.Collections.Generic.List[object]]::new()
$s.add_PhonemeReached({ param($o, $e) $events.Add([pscustomobject]@{ Kind = 'phoneme'; Text = $e.Phoneme; StartMs = $e.AudioPosition.TotalMilliseconds; DurMs = $e.Duration.TotalMilliseconds; Emphasis = [int]$e.Emphasis; Next = $e.NextPhoneme }) })
$s.add_SpeakProgress({ param($o, $e) $events.Add([pscustomobject]@{ Kind = 'word'; Text = $e.Text; StartMs = $e.AudioPosition.TotalMilliseconds; DurMs = 0; Emphasis = 0; Next = '' }) })
$s.Speak($Text)
$s.SetOutputToNull(); $s.Dispose()
$events | ConvertTo-Json -Depth 3 | Set-Content "$OutPrefix.json" -Encoding utf8
$bytes = (Get-Item "$OutPrefix.wav").Length - 44
$ph = $events | ? Kind -eq phoneme
'{0}: {1} phonemes, pcm {2:N1} ms, last event end {3:N1} ms, sum durations {4:N1} ms' -f $OutPrefix, $ph.Count, ($bytes / 2 / 22.05), (($ph[-1].StartMs) + $ph[-1].DurMs), (($ph | Measure-Object DurMs -Sum).Sum)
