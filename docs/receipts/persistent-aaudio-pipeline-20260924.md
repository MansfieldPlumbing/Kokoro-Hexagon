# Persistent QNN and AAudio pipeline receipt

Date: 2026-09-24  
Target: Samsung Galaxy S23, SM8550 / Hexagon V73  
Runtime: QAIRT 2.46.0.260424  
Voice: `af_heart`  
Capacity: 64 frames  
Audio format: 24 kHz, mono, float

## Question

Can one Android process keep a QNN front/generator context pair resident while
a second in-process PowerShell runspace feeds three chunks through one native
AAudio stream, without an unbounded PCM queue or an observed underrun?

## Test

The known-good `p01` phrase bundle was repeated three times. Repetition is
intentional: this isolates process, context, queue, and stream lifetimes from
new text-front-end behavior. The main runspace loaded the c64 front and
generator contexts once. A second, minimally initialized runspace owned the
blocking AAudio writer. A `BlockingCollection<float[]>` with capacity one was
the only inter-runspace PCM queue.

The checked source identities were:

- `src/runspace/Pipeline.ps1` SHA-256
  `6351390B4F497DBF013ED84DB80CB964980C099A6157EFB4A32796CAE7E5B8AB`
- `src/runspace/Audio.AAudio.psm1` SHA-256
  `02CC2BEAF1CEB3B869BA35876569222E2DFF0FFD16A1D1F66975B4296C0929D4`

The device startup scripts were copied to a device-local backup before the
test runner replaced them. Generated staging files and raw output remained in
the adjacent build directory or on the device.

## Device result

```text
ContextLoadMs=150.4 Buckets=1
ContextVmHwmKiB=545164
AAudioReady Rate=24000 Channels=1 Format=2 CapacityFrames=768 BurstFrames=48 QueueCapacity=1
FirstAudioQueuedMs=1630.2
Phrase=p01-1 Samples=33600 FrontMs=23.2 GenMs=346.4 EnqueueWaitMs=0.9 SnrDb=18.43 NonFinite=0
Phrase=p01-2 Samples=33600 FrontMs=7.0 GenMs=346.8 EnqueueWaitMs=0.1 SnrDb=18.43 NonFinite=0
Phrase=p01-3 Samples=33600 FrontMs=6.3 GenMs=345.2 EnqueueWaitMs=0.0 SnrDb=18.43 NonFinite=0
AAudioPlaybackStartMs=1713.4 Chunks=3 WrittenFrames=100800 PlaybackFrames=100944 XRunCount=0 PlaybackComplete=True CloseRc=0
FinalVmHwmKiB=590132 ManagedBytes=57638016
PipelineMs=6068.8 Passed=True
```

The phone speaker played all three chunks. The stream reported 100,800 frames
written, at least that many frames presented, zero underruns, complete drain,
and a clean close. The three chunks contain 4.2 seconds of audio. The process
high-water mark rose by 44,968 KiB after the contexts were resident; this is a
whole-process high-water observation, not a per-buffer allocation measurement.

## Result and boundary

Pass. Persistent QNN contexts, bounded inter-runspace handoff, synthesis during
playback, and one persistent native stream are now device-proven for three
repetitions of one prepared phrase.

This does not yet prove arbitrary-text phonemization, distinct long-form
chunks, cached tensor arenas, seamless subjective boundaries, or a lower peak
memory design. Those remain the next gates.
