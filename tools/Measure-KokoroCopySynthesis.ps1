#requires -Version 7.4
param([Parameter(Mandatory)][string]$OutputDirectory,[string]$CorrelationReceipt,[string]$LadderReceipt)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$inputRoot=Join-Path $root 'build'
$out=[IO.Path]::GetFullPath($OutputDirectory)
$build=[IO.Path]::GetFullPath((Join-Path $root 'build'))+[IO.Path]::DirectorySeparatorChar
if(-not $out.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Use a fresh output directory in this worktree build/.'}
[void][IO.Directory]::CreateDirectory($out)
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CaptureKernels.psm1')
Import-Module (Join-Path $PSScriptRoot 'Kokoro.CopySynthesisKernels.psm1')
$matrix=Get-Conv1dKernel
$length=1024;$bins=513;$hop=120;$sampleRate=24000
$window=[double[]]::new($length);$periodBand=[int[]]::new($bins)
$envelopeCounts=[double[]]::new(64);$periodCounts=[double[]]::new(12)
for($j=0;$j -lt $length;$j++){$window[$j]=0.5-0.5*[math]::Cos(2*[math]::PI*$j/$length)}
for($j=0;$j -lt $bins;$j++){
    $periodBand[$j]=[math]::Min(11,[int][math]::Floor(12*[math]::Log(1+($j*$sampleRate/$length)/100)/[math]::Log(121)))
    $envelopeCounts[[int][math]::Floor($j*64.0/$bins)]++
    $periodCounts[$periodBand[$j]]++
}
$numeric=Get-KokoroCopySynthesisKernels -Length $length -Window $window -PeriodBand $periodBand
$forward=[double[]]::new(2*$bins*$length);$inverse=[double[]]::new($length*2*$bins)
for($frequency=0;$frequency -lt $bins;$frequency++){
    $factor=if($frequency -eq 0 -or $frequency -eq $bins-1){1.0/$length}else{2.0/$length}
    for($j=0;$j -lt $length;$j++){
        $angle=2*[math]::PI*$frequency*$j/$length;$cosine=[math]::Cos($angle);$sine=[math]::Sin($angle)
        $forward[$frequency*$length+$j]=$cosine;$forward[($bins+$frequency)*$length+$j]=-$sine
        $inverse[$j*2*$bins+$frequency]=$factor*$cosine;$inverse[$j*2*$bins+$bins+$frequency]=-$factor*$sine
    }
}
$interpolation=[double[]]::new($bins*64);$periodLookup=[double[]]::new($bins*12)
for($j=0;$j -lt $bins;$j++){
    $position=$j*64.0/$bins-0.5;$lower=[int][math]::Floor($position);$fraction=$position-$lower
    if($lower -lt 0){$lower=0;$fraction=0};if($lower -ge 63){$lower=63;$fraction=0}
    $interpolation[$j*64+$lower]=1-$fraction
    if($fraction -gt 0){$interpolation[$j*64+$lower+1]=$fraction}
    $periodLookup[$j*12+$periodBand[$j]]=1
}
function Invoke-CopyMatrix([double[]]$Source,[double[]]$MatrixWeights,[double[]]$Destination){
    [Array]::Clear($Destination)
    $matrix.Invoke($Source,$Source.Length,1,$MatrixWeights,$Destination.Length,1,0,$Destination)
}
function Read-CopyFloat([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith([IO.Path]::GetFullPath($inputRoot)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Inputs must stay inside the authorized build directory.'}
    $bytes=[IO.File]::ReadAllBytes($full)
    if($bytes.Length -lt 4 -or $bytes.Length%4){throw 'Float input extent differs.'}
    $single=[float[]]::new($bytes.Length/4);[Buffer]::BlockCopy($bytes,0,$single,0,$bytes.Length)
    $values=[double[]]::new($single.Length);[Array]::Copy($single,$values,$single.Length)
    if(-not [double]::IsFinite([Linq.Enumerable]::Min($values)) -or -not [double]::IsFinite([Linq.Enumerable]::Max($values))){throw 'Nonfinite float input.'}
    [pscustomobject]@{Values=$values;Path=$full;SHA256=(Get-FileHash -LiteralPath $full).Hash}
}
function Write-CopyWave([string]$Path,[double[]]$Values){
    # RIFF/WAVE: format tag 3, mono IEEE float32, 24 kHz; fact stores sample count.
    $single=[float[]]$Values;$bytes=[byte[]]::new(4*$single.Length);[Buffer]::BlockCopy($single,0,$bytes,0,$bytes.Length)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
    $writer=[IO.BinaryWriter]::new($stream)
    try{
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](50+$bytes.Length));$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([int]18);$writer.Write([int16]3);$writer.Write([int16]1);$writer.Write([int]24000);$writer.Write([int]96000);$writer.Write([int16]4);$writer.Write([int16]32);$writer.Write([int16]0)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('fact'));$writer.Write([int]4);$writer.Write([int]$single.Length)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int]$bytes.Length);$writer.Write($bytes)
    }finally{$writer.Dispose()}
    # Verify the exact written payload, including finite, float32 roundtrip used for scoring.
    $readback=[IO.File]::ReadAllBytes($Path)
    if($readback.Length -ne 58+$bytes.Length -or [BitConverter]::ToInt32($readback,54) -ne $bytes.Length){throw 'WAV extent verification failed.'}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    $readData=[byte[]]::new($bytes.Length);[Buffer]::BlockCopy($readback,58,$readData,0,$readData.Length)
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($readData)) -cne $hash){throw 'WAV data verification failed.'}
    [Array]::Copy($single,$Values,$single.Length)
}
function Get-CopyF0([double[]]$Values,[int]$Sample){
    $position=$Sample/300.0;$at=[int][math]::Floor($position)
    if($at -ge $Values.Length-1){return $Values[-1]}
    $fraction=$position-$at
    $Values[$at]*(1-$fraction)+$Values[$at+1]*$fraction
}
function Get-CopyCorrelation([double[]]$left,[double[]]$right){
    if($left.Length -ne $right.Length -or $left.Length -lt 2){throw 'Correlation requires equal paired populations.'}
    $result=$numeric.Correlation.Invoke($left,$right)
    if(-not [double]::IsFinite($result) -or $result -lt -1.0 -or $result -gt 1.0){throw 'Correlation is outside [-1, 1].'}
    $result
}
if($CorrelationReceipt){
    $sourcePath=[IO.Path]::GetFullPath($CorrelationReceipt)
    if(-not $sourcePath.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)){throw 'Rescore only a receipt inside this worktree build/.'}
    $old=Import-Clixml -LiteralPath $sourcePath
    if($old.WindowSamples -ne $length -or $old.HopSamples -ne $hop -or $old.SampleRate -ne 24000 -or $old.EnvelopeBands -ne 64){throw 'Saved analysis settings differ.'}
    # Independent affine and offset checks of centered Pearson correlation.
    foreach($pair in @(@([double[]]@(1,2,3),[double[]]@(2,4,6),1.0),
        @([double[]]@(1,2,3),[double[]]@(6,4,2),-1.0),
        @([double[]]@((1e12-2),(1e12-1),1e12,(1e12+1),(1e12+2)),[double[]]@(-4,-2,0,2,4),1.0))){
        if([math]::Abs((Get-CopyCorrelation $pair[0] $pair[1])-$pair[2]) -gt 1e-12){throw 'Centered correlation check failed.'}
    }
    function Read-CopySavedWave([string]$Path){
        $full=[IO.Path]::GetFullPath($Path)
        if(-not $full.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)){throw 'Saved audio is outside this worktree build/.'}
        $bytes=[IO.File]::ReadAllBytes($full)
        if($bytes.Length -lt 58 -or [Text.Encoding]::ASCII.GetString($bytes,0,4) -cne 'RIFF' -or
            [Text.Encoding]::ASCII.GetString($bytes,50,4) -cne 'data' -or [BitConverter]::ToInt16($bytes,20) -ne 3 -or
            [BitConverter]::ToInt16($bytes,22) -ne 1 -or [BitConverter]::ToInt32($bytes,24) -ne 24000 -or
            [BitConverter]::ToInt16($bytes,34) -ne 32 -or [BitConverter]::ToInt32($bytes,54) -ne $bytes.Length-58 -or ($bytes.Length-58)%4){throw 'Saved WAV format/extent differs.'}
        $single=[float[]]::new(($bytes.Length-58)/4);[Buffer]::BlockCopy($bytes,58,$single,0,4*$single.Length)
        $values=[double[]]::new($single.Length);[Array]::Copy($single,$values,$single.Length)
        [pscustomobject]@{Values=$values;SHA256=(Get-FileHash -LiteralPath $full).Hash;Path=$full}
    }
    $scoreClock=[Diagnostics.Stopwatch]::StartNew();$results=[Collections.Generic.List[object]]::new()
    $waveHashes=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $windowEnergy=$numeric.Dot.Invoke($window,$window)
    foreach($group in @($old.Results|Group-Object Reference)){
        $stockWave=Read-CopySavedWave $group.Group[0].StockWav;$waveHashes[$stockWave.Path]=$stockWave.SHA256
        $stock=$stockWave.Values;$frames=[int]$group.Group[0].Frames
        $grain=[double[]]::new($length);$spec=[double[]]::new(2*$bins);$power=[double[]]::new($bins);$stats=[double[]]::new(100)
        $rmsStock=[double[]]::new($frames);$stockEnvelopes=[object[]]::new($frames);$peakPower=0.0
        for($frame=0;$frame -lt $frames;$frame++){
            $numeric.Window.Invoke($stock,$frame*$hop,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
            $numeric.Power.Invoke($spec,$power,2.0/($length*$windowEnergy));$rmsStock[$frame]=[math]::Sqrt([Linq.Enumerable]::Sum($power))
            $peakPower=[math]::Max($peakPower,[Linq.Enumerable]::Max($power));[Array]::Clear($stats);$numeric.Bands.Invoke($power,0.0,$stats)
            $envelope=[double[]]::new(64);for($j=0;$j -lt 64;$j++){$envelope[$j]=$stats[$j]/$envelopeCounts[$j]};$stockEnvelopes[$frame]=$envelope
        }
        $gate=[Linq.Enumerable]::Max($rmsStock)*0.001;$floorPower=[math]::Max(1e-30,$peakPower*1e-8)
        $active=@(0..($frames-1)|Where-Object {$rmsStock[$_] -ge $gate})
        foreach($row in $group.Group){
            if($active.Count -ne $row.ActiveFrames){throw 'Rescored stock frame mask differs from the original analysis.'}
            $candidate=Read-CopySavedWave $row.Wav;$waveHashes[$candidate.Path]=$candidate.SHA256
            if($candidate.Values.Length -ne $stock.Length){throw 'Rescored audio lengths differ.'}
            $rmsCandidate=[double[]]::new($frames);$logStock=[double[]]::new(64*$active.Count);$logCandidate=[double[]]::new($logStock.Length)
            $left=[double[]]::new(64);$right=[double[]]::new(64);$envelope=[double[]]::new(64);$paired=0
            for($frame=0;$frame -lt $frames;$frame++){
                $numeric.Window.Invoke($candidate.Values,$frame*$hop,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
                $numeric.Power.Invoke($spec,$power,2.0/($length*$windowEnergy));$rmsCandidate[$frame]=[math]::Sqrt([Linq.Enumerable]::Sum($power))
                if($rmsStock[$frame] -lt $gate){continue}
                [Array]::Clear($stats);$numeric.Bands.Invoke($power,0.0,$stats)
                for($j=0;$j -lt 64;$j++){$envelope[$j]=$stats[$j]/$envelopeCounts[$j]}
                $numeric.Log.Invoke($stockEnvelopes[$frame],$floorPower,$left);$numeric.Log.Invoke($envelope,$floorPower,$right)
                [Array]::Copy($left,0,$logStock,64*$paired,64);[Array]::Copy($right,0,$logCandidate,64*$paired,64);$paired++
            }
            if($paired -ne $active.Count){throw 'Paired envelope frame count differs.'}
            $corrected=[ordered]@{};foreach($property in $row.PSObject.Properties){$corrected[$property.Name]=$property.Value}
            $corrected.SpectralEnvelopeCorrelation=Get-CopyCorrelation $logStock $logCandidate
            $corrected.TemporalEnvelopeCorrelation=Get-CopyCorrelation $rmsStock $rmsCandidate
            $corrected.EnvelopePairs=$logStock.Length;$corrected.SpectralFramePopulation='Paired 64-band log powers pooled over the original stock-active frames'
            $corrected.TemporalFramePopulation='Paired window RMS over every original frame'
            $corrected.WavSHA256=$candidate.SHA256;$corrected.StockWavSHA256=$stockWave.SHA256
            $results.Add([pscustomobject]$corrected)
            Write-Host "$($row.Reference) $($row.Mode) correlation=$($corrected.SpectralEnvelopeCorrelation.ToString('F6'))"
        }
    }
    foreach($wavePath in $waveHashes.Keys){if((Get-FileHash -LiteralPath $wavePath).Hash -cne $waveHashes[$wavePath]){throw 'Saved WAV changed during rescoring.'}}
    $receipt=[pscustomobject]@{Status='Passed';Operation='CorrelationOnly';RenderingReceipt=$sourcePath;RenderingReceiptSHA256=(Get-FileHash $sourcePath).Hash;
        RenderingKernelSHA256=$old.KernelSHA256;RenderingHarnessSHA256=$old.HarnessSHA256;
        ScoringKernelSHA256=(Get-FileHash (Join-Path $PSScriptRoot 'Kokoro.CopySynthesisKernels.psm1')).Hash;ScoringHarnessSHA256=(Get-FileHash $PSCommandPath).Hash;
        AnalysisReconstructedFromSavedWavs=$true;Resynthesized=$false;WavFilesUnchanged=$true;
        Correlation='sum((x-mean(x))*(y-mean(y))) / (sqrt(sum((x-mean(x))^2))*sqrt(sum((y-mean(y))^2)))';
        LsdRecomputed=$false;LsdSource='Original rendering receipt, unchanged';SampleRate=24000;HopSamples=$hop;WindowSamples=$length;EnvelopeBands=64;
        RenderingElapsedSeconds=$old.ElapsedSeconds;RescoreElapsedSeconds=$scoreClock.Elapsed.TotalSeconds;Results=$results.ToArray()}
    $receipt|Export-Clixml -LiteralPath (Join-Path $out 'receipt.clixml') -Depth 8
    $receipt
    return
}
function Measure-CopyCandidate([double[]]$candidate,[string]$mode){
    $gain=[math]::Sqrt($numeric.Dot.Invoke($stock,$stock)/$numeric.Dot.Invoke($candidate,$candidate))
    if(-not [double]::IsFinite($gain)){throw 'Nonfinite level match.'}
    $numeric.Scale.Invoke($candidate,$gain)
    if(-not [double]::IsFinite([Linq.Enumerable]::Min($candidate)) -or -not [double]::IsFinite([Linq.Enumerable]::Max($candidate))){throw 'Nonfinite synthesis.'}
    $wav=Join-Path $out ($reference.Name+'-'+$mode+'.wav');Write-CopyWave $wav $candidate
    $rms=[double[]]::new($frames);$sumSquared=0.0;$active=0
    $stockLog=[double[]]::new($bins);$synthLog=[double[]]::new($bins)
    $envStockLog=[double[]]::new(64);$envSynthLog=[double[]]::new(64);$envSynth=[double[]]::new(64)
    $pairedStock=[double[]]::new(64*$frames);$pairedSynth=[double[]]::new(64*$frames)
    $grain=[double[]]::new($length);$spec=[double[]]::new(2*$bins);$power=[double[]]::new($bins);$stats=[double[]]::new(100)
    $gate=[Linq.Enumerable]::Max($stockRms)*0.001
    for($frame=0;$frame -lt $frames;$frame++){
        $numeric.Window.Invoke($candidate,$frame*$hop,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
        $numeric.Power.Invoke($spec,$power,2.0/($length*$windowEnergy));$rms[$frame]=[math]::Sqrt([Linq.Enumerable]::Sum($power))
        if($stockRms[$frame] -lt $gate){continue}
        $numeric.Log.Invoke($analysis[$frame].Power,$floorPower,$stockLog);$numeric.Log.Invoke($power,$floorPower,$synthLog)
        $sumSquared+=$numeric.SquaredDistance.Invoke($stockLog,$synthLog)
        [Array]::Clear($stats);$numeric.Bands.Invoke($power,0.0,$stats)
        for($j=0;$j -lt 64;$j++){$envSynth[$j]=$stats[$j]/$envelopeCounts[$j]}
        $numeric.Log.Invoke($analysis[$frame].Envelope,$floorPower,$envStockLog);$numeric.Log.Invoke($envSynth,$floorPower,$envSynthLog)
        [Array]::Copy($envStockLog,0,$pairedStock,64*$active,64);[Array]::Copy($envSynthLog,0,$pairedSynth,64*$active,64);$active++
    }
    if($active -lt 1){throw 'No active evaluation frames.'}
    $left=[double[]]::new(64*$active);$right=[double[]]::new($left.Length)
    [Array]::Copy($pairedStock,$left,$left.Length);[Array]::Copy($pairedSynth,$right,$right.Length)
    [pscustomobject]@{Reference=$reference.Name;Label=$reference.Label;Mode=$mode;Samples=$samples;Frames=$frames;ActiveFrames=$active;
        LsdDb=[math]::Sqrt($sumSquared/($active*$bins));SpectralEnvelopeCorrelation=(Get-CopyCorrelation $left $right);
        TemporalEnvelopeCorrelation=(Get-CopyCorrelation $stockRms $rms);LevelMatchGain=$gain;StockWav=$stockWave;Wav=$wav;
        WavSHA256=(Get-FileHash $wav).Hash;PcmInput=$reference.Pcm.Path;PcmSHA256=$reference.Pcm.SHA256;F0Input=$reference.Pitch.Path;F0SHA256=$reference.Pitch.SHA256}
}
function Get-CopyOverlap([double[]]$Values){
    $grain=[double[]]::new($length);$sum=[double[]]::new($Values.Length);$weights=[double[]]::new($Values.Length)
    for($center=0;$center -lt $Values.Length;$center+=$hop){
        $numeric.Window.Invoke($Values,$center,$constantWindow,$grain)
        $numeric.Overlap.Invoke($grain,$center,$constantWindow,$sum,$weights)
    }
    if([Linq.Enumerable]::Min($weights) -le 0){throw 'Uncovered overlap-add sample.'}
    $effective=[double[]]$weights.Clone();$numeric.Normalize.Invoke($effective,$weights)
    if([Linq.Enumerable]::Min($effective) -ne 1.0 -or [Linq.Enumerable]::Max($effective) -ne 1.0){throw 'Normalized overlap-add is not constant.'}
    $numeric.Normalize.Invoke($sum,$weights)
    ,$sum
}
if($LadderReceipt){
    $ladderSource=[IO.Path]::GetFullPath($LadderReceipt)
    if(-not $ladderSource.StartsWith($build,[StringComparison]::OrdinalIgnoreCase)){throw 'Use the original run2 receipt in this worktree build/.'}
    $baseline=Import-Clixml -LiteralPath $ladderSource
    if(-not $env:KOKORO_NOTES){throw 'Set KOKORO_NOTES to the project notes folder (Invoke-KokoroDevelopment.ps1 sets it).'}
    $baselineMetrics=Import-Clixml (Join-Path $env:KOKORO_NOTES 'reference/baselines/copy-synthesis-correlation-20261013.clixml')
    if($baselineMetrics.RenderingReceiptSHA256 -cne (Get-FileHash $ladderSource).Hash){throw 'Corrected baseline metrics do not match run2.'}
    if($baseline.SampleRate -ne $sampleRate -or $baseline.WindowSamples -ne $length -or $baseline.HopSamples -ne $hop -or $baseline.EnvelopeBands -ne 64){throw 'Run2 settings differ.'}
    $baselineHashes=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($baselineResult in $baseline.Results){foreach($wave in @($baselineResult.Wav,$baselineResult.StockWav)){$baselineHashes[$wave]=(Get-FileHash $wave).Hash}}
    $constantWindow=[double[]]::new($length);$windowSums=[double[]]::new($hop)
    for($j=0;$j -lt $length;$j++){$windowSums[$j%$hop]+=$window[$j]}
    for($j=0;$j -lt $length;$j++){$constantWindow[$j]=$window[$j]/$windowSums[$j%$hop]}
    $constantSums=[double[]]::new($hop)
    for($j=0;$j -lt $length;$j++){$constantSums[$j%$hop]+=$constantWindow[$j]}
    $constantDeviation=0.0;foreach($value in $constantSums){$constantDeviation=[math]::Max($constantDeviation,[math]::Abs($value-1))}
    if($constantDeviation -gt 1e-12){throw 'Constant-sum window assertion failed.'}
    # Exercise continuous tracks with an affine amplitude and a known carrier.
    $trackPhase=[double[]]::new(360);$trackAmplitude=[double[][]]@(@(0,1),@(0,2),@(0,3));$trackOffset=[double[][]]@(@(0,0),@(0,0),@(0,0))
    $trackResult=[double[]]::new(360);$numeric.Tracks.Invoke($trackPhase,$trackAmplitude,$trackOffset,120,$trackResult)
    for($j=0;$j -lt 240;$j++){if([math]::Abs($trackResult[$j]-(1+$j/120.0)) -gt 1e-12){throw 'Harmonic amplitude interpolation assertion failed.'}}
    $continuity=[Collections.Generic.List[object]]::new();$sharedAnalysis=[Collections.Generic.List[object]]::new()
    $voicingSource=Join-Path $inputRoot 'generator-constants-gate2b-20261012-140157/generator-corpus-6/source/kokoro/istftnet.py'
    $voicingSourceHash='66515CB3369D1C0BBB2015AD7293D019FB1F80FEFCB2D56E70E73B6B146AF11C'
    if((Get-FileHash $voicingSource).Hash -cne $voicingSourceHash){throw 'Pinned voicing source differs.'}
    $voicedThreshold=10.0
}
# Meaningful independent transform checks before processing captures.
$test=[double[]]::new($length);$test[13]=1.0;$spectrum=[double[]]::new(2*$bins);$reconstructed=[double[]]::new($length)
Invoke-CopyMatrix $test $forward $spectrum;Invoke-CopyMatrix $spectrum $inverse $reconstructed
if($numeric.SquaredDistance.Invoke($test,$reconstructed) -gt 1e-20){throw 'DFT inverse impulse check failed.'}
for($j=0;$j -lt $length;$j++){$test[$j]=[math]::Cos(2*[math]::PI*17*$j/$length)}
Invoke-CopyMatrix $test $forward $spectrum
if([math]::Abs($spectrum[17]-$length/2) -gt 1e-8 -or [math]::Abs($spectrum[$bins+17]) -gt 1e-8){throw 'DFT sinusoid check failed.'}
$testPitch=[double[]]@(150,150,150,150);$testPhase=[double[]]::new(1024);$numeric.Phase.Invoke($testPitch,$testPhase)
for($j=0;$j -lt $testPhase.Length;$j++){
    $expected=(2*[math]::PI*150*$j/24000)%(2*[math]::PI)
    $phaseError=[math]::Abs($testPhase[$j]-$expected);$phaseError=[math]::Min($phaseError,2*[math]::PI-$phaseError)
    if($phaseError -gt 1e-11){throw 'Accumulated F0 phase check failed.'}
}

$prior=Import-Clixml (Join-Path $inputRoot 'generator-constants-full-corpus-20261012-143702-run.clixml')
$training=@($prior.Gate.GeneratorTraining)
$pitchRows=foreach($capture in $training){
    $pitch=Read-CopyFloat (Join-Path $capture.Directory 'f0.f32')
    $positive=[double[]]@($pitch.Values|Where-Object {$_ -gt 0});[Array]::Sort($positive)
    if(-not $positive.Length){throw 'Corpus F0 is unavailable.'}
    [pscustomobject]@{Root=$capture.Directory;Phonemes=$capture.Phonemes;P95=$positive[[int][math]::Floor(0.95*($positive.Length-1))]}
}
$question=@($pitchRows|Where-Object {$_.Phonemes.Contains('?')})[0]
$fricatives=$pitchRows[2]
$high=@($pitchRows|Where-Object {$_.Root -cne $question.Root -and $_.Root -cne $fricatives.Root}|Sort-Object P95 -Descending)[0]
$references=[Collections.Generic.List[object]]::new()
$peachPcm=Join-Path $inputRoot 'speak-20261010-h0-fast/job-input/decoder-generator-fixture-20261009/expected-pcm-f32.bin'
$peachPitch=Join-Path $inputRoot 'speak-20261010-h0-fast/generator/f0.f32'
if((Get-FileHash $peachPitch).Hash -cne (Get-FileHash (Join-Path $inputRoot 'speak-20261010-h0-fast/front-end/F0.f32')).Hash){throw 'Peach fixture input and generator F0 differ.'}
$references.Add([pscustomobject]@{Name='peach-fixture';Label='stock synthesis of the bank-input fixture';Pcm=(Read-CopyFloat $peachPcm);Pitch=(Read-CopyFloat $peachPitch)})
foreach($selection in @(@('corpus-high-pitch',$high),@('corpus-consonants',$fricatives),@('corpus-question',$question))){
    $references.Add([pscustomobject]@{Name=$selection[0];Label=$selection[1].Phonemes;Pcm=(Read-CopyFloat (Join-Path $selection[1].Root 'output.f32'));Pitch=(Read-CopyFloat (Join-Path $selection[1].Root 'f0.f32'))})
}
# Reuse the entrypoint's existing NPY reader as a trusted AST body, without
# invoking its bank workflow (which uses JSON). This does not evaluate input text.
$archivePath=Join-Path $inputRoot 'unit-selection-20261010/target-eval.npz'
$stockPath=Join-Path $inputRoot 'unit-selection-20261010/target-stock.wav'
$extraPeach='Skipped: original-stock peach F0 is unavailable.'
if((Test-Path -LiteralPath $archivePath) -and (Test-Path -LiteralPath $stockPath)){
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Invoke-KokoroDevelopment.ps1'),[ref]$null,[ref]$null)
    $reader=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-BankNpy'},$true))
    if($reader.Count -ne 1){throw 'Existing NPY reader is not unique.'}
    $archive=[IO.Compression.ZipFile]::OpenRead($archivePath)
    try{
        $variables=[Collections.Generic.List[Management.Automation.PSVariable]]::new()
        $variables.Add([Management.Automation.PSVariable]::new('Zip',$archive));$variables.Add([Management.Automation.PSVariable]::new('ArrayName','F0'))
        $npy=@($reader[0].Body.GetScriptBlock().InvokeWithContext($null,$variables,@()))[0]
        if($npy.Type -cne '<f4'){throw 'Original-stock F0 must be float32.'}
        $single=[float[]]::new(($npy.Bytes.Length-$npy.Offset)/4);[Buffer]::BlockCopy($npy.Bytes,$npy.Offset,$single,0,4*$single.Length)
        $pitch=[double[]]::new($single.Length);[Array]::Copy($single,$pitch,$single.Length)
    }finally{$archive.Dispose()}
    $wave=[IO.File]::ReadAllBytes($stockPath)
    # This existing capture uses the project's 44-byte PCM16 header. Reject other layouts.
    if($wave.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($wave,0,4) -cne 'RIFF' -or
        [Text.Encoding]::ASCII.GetString($wave,36,4) -cne 'data' -or [BitConverter]::ToInt16($wave,20) -ne 1 -or
        [BitConverter]::ToInt16($wave,22) -ne 1 -or [BitConverter]::ToInt32($wave,24) -ne 24000 -or
        [BitConverter]::ToInt16($wave,34) -ne 16 -or [BitConverter]::ToInt32($wave,40) -ne $wave.Length-44){throw 'Original-stock WAV layout differs.'}
    $pcm16=[int16[]]::new(($wave.Length-44)/2);[Buffer]::BlockCopy($wave,44,$pcm16,0,$wave.Length-44)
    $pcm=[double[]]::new($pcm16.Length);[Array]::Copy($pcm16,$pcm,$pcm16.Length);$numeric.Scale.Invoke($pcm,1.0/32768)
    $references.Add([pscustomobject]@{Name='peach-original';Label='stock end-to-end peach, existing 16-bit reference';Pcm=[pscustomobject]@{Values=$pcm;Path=$stockPath;SHA256=(Get-FileHash $stockPath).Hash};Pitch=[pscustomobject]@{Values=$pitch;Path=$archivePath;SHA256=(Get-FileHash $archivePath).Hash}})
    $extraPeach='Included: captured F0 in existing target-eval.npz; existing PowerShell NPY reader reused.'
}
$rows=[Collections.Generic.List[object]]::new();$windowEnergy=$numeric.Dot.Invoke($window,$window)
$clock=[Diagnostics.Stopwatch]::StartNew()
foreach($reference in $references){
    $analysisClock=[Diagnostics.Stopwatch]::StartNew()
    $stock=$reference.Pcm.Values;$pitch=$reference.Pitch.Values;$samples=$stock.Length
    if($LadderReceipt){
        $baselineRow=@($baseline.Results|Where-Object {$_.Reference -ceq $reference.Name -and $_.Mode -ceq 'copy'})
        if($baselineRow.Count -ne 1 -or $baselineRow[0].PcmSHA256 -cne $reference.Pcm.SHA256 -or $baselineRow[0].F0SHA256 -cne $reference.Pitch.SHA256){throw 'Ladder inputs differ from run2.'}
    }
    if($samples -ne 300*$pitch.Length){throw 'PCM/F0 timebase extent differs.'}
    $positive=[double[]]@($pitch|Where-Object {$_ -gt 0});[Array]::Sort($positive)
    if(-not $positive.Length -or -not [double]::IsFinite($positive[-1])){throw 'No valid captured F0.'}
    $fallback=$positive[[int][math]::Floor($positive.Length/2)]
    $carrier=[double[]]$pitch.Clone();for($j=0;$j -lt $carrier.Length;$j++){if($carrier[$j] -le 0){$carrier[$j]=$fallback}}
    $phase=[double[]]::new($samples);$numeric.Phase.Invoke($carrier,$phase)
    $noise=[double[]]::new($samples);$randomBytes=[byte[]]::new($samples);([Random]::new(20261013)).NextBytes($randomBytes);$numeric.WhiteNoise.Invoke($randomBytes,$noise)
    $frames=[int][math]::Ceiling($samples/[double]$hop);$analysis=[object[]]::new($frames);$stockRms=[double[]]::new($frames)
    $grain=[double[]]::new($length);$spec=[double[]]::new(2*$bins);$power=[double[]]::new($bins);$bandStats=[double[]]::new(100)
    $envBin=[double[]]::new($bins);$periodBin=[double[]]::new($bins);$ones=[double[]]::new($bins);[Array]::Fill($ones,1.0)
    for($frame=0;$frame -lt $frames;$frame++){
        $center=$frame*$hop;$numeric.Window.Invoke($stock,$center,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
        $numeric.Power.Invoke($spec,$power,2.0/($length*$windowEnergy));[Array]::Clear($bandStats)
        $numeric.Bands.Invoke($power,(Get-CopyF0 $pitch $center),$bandStats)
        $envelope=[double[]]::new(64);$periodicity=[double[]]::new(12)
        for($j=0;$j -lt 64;$j++){$envelope[$j]=$bandStats[$j]/$envelopeCounts[$j]}
        for($j=0;$j -lt 12;$j++){
            $coverage=$bandStats[88+$j]/$periodCounts[$j]
            $periodicity[$j]=if($bandStats[64+$j] -gt 1e-30 -and $coverage -lt 0.999){[math]::Clamp(($bandStats[76+$j]/$bandStats[64+$j]-$coverage)/(1-$coverage),0.0,1.0)}else{0.0}
        }
        $stockRms[$frame]=[math]::Sqrt([Linq.Enumerable]::Sum($power))
        $analysis[$frame]=[pscustomobject]@{Envelope=$envelope;Periodicity=$periodicity;Power=$power.Clone()}
        if($LadderReceipt){$analysis[$frame]|Add-Member Spectrum $spec.Clone()}
    }
    $stockWave=Join-Path $out ($reference.Name+'-stock.wav');Write-CopyWave $stockWave $stock
    $floorPower=[math]::Max(1e-30,($analysis|ForEach-Object{[Linq.Enumerable]::Max([double[]]$_.Power)}|Measure-Object -Maximum).Maximum*1e-8)
    if($LadderReceipt){
        $sharedAnalysis.Add([pscustomobject]@{Reference=$reference.Name;Seconds=$analysisClock.Elapsed.TotalSeconds})
        $rungClock=[Diagnostics.Stopwatch]::StartNew()
        $measuredPhase=[double[]]::new($samples);$numeric.Phase.Invoke($pitch,$measuredPhase)
        $measuredAmplitude=[double[][]]::new($frames);$measuredOffset=[double[][]]::new($frames)
        $run2Amplitude=[double[][]]::new($frames);$zeroOffset=[double[][]]::new($frames)
        $lastOffset=[double[]]::new(1201);$windowTotal=[Linq.Enumerable]::Sum($window)
        for($frame=0;$frame -lt $frames;$frame++){
            $center=$frame*$hop;$f0=Get-CopyF0 $carrier $center;$data=$analysis[$frame]
            Invoke-CopyMatrix $data.Envelope $interpolation $envBin;Invoke-CopyMatrix $data.Periodicity $periodLookup $periodBin
            $lo=[math]::Max(0,[int][math]::Floor(($center-$length/2)/300));$hi=[math]::Min($carrier.Length-1,[int][math]::Ceiling(($center+$length/2)/300))
            $maximum=0.0;for($j=$lo;$j -le $hi;$j++){$maximum=[math]::Max($maximum,$carrier[$j])}
            $run2Limit=1+[int][math]::Floor(11999/$maximum)
            $run2Amplitude[$frame]=[double[]]::new($run2Limit);$numeric.Amplitudes.Invoke($envBin,$periodBin,$f0,$run2Amplitude[$frame])
            $zeroOffset[$frame]=[double[]]::new(1)
            $capturedF0=Get-CopyF0 $pitch $center
            $measuredLimit=if($capturedF0 -gt $voicedThreshold){1+[int][math]::Floor(11999/$capturedF0)}else{1}
            $measuredAmplitude[$frame]=[double[]]::new($measuredLimit);$measuredOffset[$frame]=[double[]]::new($measuredLimit)
            for($harmonic=1;$harmonic -lt $measuredLimit;$harmonic++){
                $frequency=$harmonic*$capturedF0
                $position=$frequency*$length/$sampleRate;$bin=[int][math]::Floor($position);$fraction=$position-$bin
                # Center the STFT phase BEFORE interpolating its complex samples.
                # For an even window, the center shift is (-1)^bin at DFT bins.
                $sign=if($bin%2){-1.0}else{1.0};$nextSign=-$sign
                $real=$data.Spectrum[$bin]*$sign*(1-$fraction)+$data.Spectrum[$bin+1]*$nextSign*$fraction
                $imag=$data.Spectrum[$bins+$bin]*$sign*(1-$fraction)+$data.Spectrum[$bins+$bin+1]*$nextSign*$fraction
                $amplitude=2*[math]::Sqrt($real*$real+$imag*$imag)/$windowTotal
                $measuredAmplitude[$frame][$harmonic]=$amplitude
                $offset=[math]::Atan2($imag,$real)-$harmonic*$measuredPhase[$center]
                $delta=$offset-$lastOffset[$harmonic];$delta-=(2*[math]::PI)*[math]::Floor(($delta+[math]::PI)/(2*[math]::PI))
                if($amplitude -gt 1e-12){$lastOffset[$harmonic]+=$delta}
                $measuredOffset[$frame][$harmonic]=$lastOffset[$harmonic]
            }
        }
        $harmonicPart=[double[]]::new($samples);$residual=[double[]]::new($samples)
        $numeric.Tracks.Invoke($measuredPhase,$measuredAmplitude,$measuredOffset,$hop,$harmonicPart)
        $harmonicPart=Get-CopyOverlap $harmonicPart
        $numeric.Subtract.Invoke($stock,$harmonicPart,$residual)
        $candidate=[double[]]::new($samples);$numeric.Add.Invoke($harmonicPart,$residual,$candidate)
        $row=Measure-CopyCandidate $candidate 'R1';$row|Add-Member RuntimeSeconds $rungClock.Elapsed.TotalSeconds;$rows.Add($row)
        if($row.LsdDb -gt 1e-9){throw 'R1 reconstruction gate failed.'}
        Write-Host "$($reference.Name) R1 complete"
        foreach($rung in 'R4c'){
            $rungClock.Restart();$part=[double[]]::new($samples)
            $amplitudeTrack=$run2Amplitude
            $offsetTrack=$zeroOffset
            $numeric.Tracks.Invoke($phase,$amplitudeTrack,$offsetTrack,$hop,$part);$part=Get-CopyOverlap $part
            if($rung -ceq 'R4c'){
                $noiseSum=[double[]]::new($samples);$noiseWeights=[double[]]::new($samples);$shaped=[double[]]::new(2*$bins)
                for($frame=0;$frame -lt $frames;$frame++){
                    $center=$frame*$hop;$data=$analysis[$frame]
                    Invoke-CopyMatrix $data.Envelope $interpolation $envBin;Invoke-CopyMatrix $data.Periodicity $periodLookup $periodBin
                    $numeric.Window.Invoke($noise,$center,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
                    $numeric.Noise.Invoke($spec,$envBin,$periodBin,$shaped);Invoke-CopyMatrix $shaped $inverse $grain
                    for($j=0;$j -lt $length;$j++){$grain[$j]/=$windowSums[$j%$hop]}
                    $numeric.Overlap.Invoke($grain,$center,$constantWindow,$noiseSum,$noiseWeights)
                }
                $numeric.Normalize.Invoke($noiseSum,$noiseWeights);$numeric.Add.Invoke($part,$noiseSum,$candidate)
            }
            $row=Measure-CopyCandidate $candidate $rung;$row|Add-Member RuntimeSeconds $rungClock.Elapsed.TotalSeconds;$rows.Add($row)
            Write-Host "$($reference.Name) $rung complete"
        }
        $continuity.Add([pscustomobject]@{Reference=$reference.Name;PhaseResets=$false;AmplitudeInterpolation='Linear between per-harmonic frame knots';
            FrequencyInterpolation='Shared sample-clock F0 integral; measured phase offsets unwrapped, smoothstep interpolated';
            RawConstantWindowMaxDeviation=$constantDeviation;NormalizedWindowMaxDeviation=0.0;Residual='Stock minus the continuous R1 harmonic waveform; R2 and R3 skipped'})
        $baselineWave=Join-Path $out ($reference.Name+'-R4.wav')
        Copy-Item -LiteralPath $baselineRow[0].Wav -Destination $baselineWave
        if((Get-FileHash $baselineWave).Hash -cne (Get-FileHash $baselineRow[0].Wav).Hash){throw 'R4 byte mismatch against run2.'}
        if((Get-FileHash $stockWave).Hash -cne (Get-FileHash $baselineRow[0].StockWav).Hash){throw 'Stock reference byte mismatch against run2.'}
        $saved=@($baselineMetrics.Results|Where-Object {$_.Reference -ceq $reference.Name -and $_.Mode -ceq 'copy'})
        if($saved.Count -ne 1){throw 'Missing corrected R4 metrics.'}
        $savedRow=[ordered]@{};foreach($property in $saved[0].PSObject.Properties){$savedRow[$property.Name]=$property.Value}
        $savedRow.Mode='R4';$savedRow.Wav=$baselineWave;$savedRow.StockWav=$stockWave
        $savedRow.RuntimeSeconds=$null;$savedRow.RuntimeScope='Reused run2 WAV and corrected metrics; not re-rendered. Original 596.114452 s covers all references and both original modes, not R4 alone.'
        $rows.Add([pscustomobject]$savedRow)
        if((Get-FileHash -LiteralPath $reference.Pcm.Path).Hash -cne $reference.Pcm.SHA256 -or (Get-FileHash -LiteralPath $reference.Pitch.Path).Hash -cne $reference.Pitch.SHA256){throw 'Read-only input changed.'}
        continue
    }
    foreach($mode in 'copy','buzzy'){
        $synth=[double[]]::new($samples);$weights=[double[]]::new($samples);$shaped=[double[]]::new(2*$bins)
        for($frame=0;$frame -lt $frames;$frame++){
            $center=$frame*$hop;$data=$analysis[$frame]
            Invoke-CopyMatrix $data.Envelope $interpolation $envBin
            if($mode -ceq 'buzzy'){[Array]::Fill($periodBin,1.0);[Array]::Clear($grain)}else{
                Invoke-CopyMatrix $data.Periodicity $periodLookup $periodBin
                $numeric.Window.Invoke($noise,$center,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
                $numeric.Noise.Invoke($spec,$envBin,$periodBin,$shaped);Invoke-CopyMatrix $shaped $inverse $grain
            }
            $f0=Get-CopyF0 $carrier $center
            $lo=[math]::Max(0,[int][math]::Floor(($center-$length/2)/300));$hi=[math]::Min($carrier.Length-1,[int][math]::Ceiling(($center+$length/2)/300))
            $maximum=0.0;for($j=$lo;$j -le $hi;$j++){$maximum=[math]::Max($maximum,$carrier[$j])}
            $amplitudes=[double[]]::new(1+[int][math]::Floor(11999/$maximum))
            $numeric.Amplitudes.Invoke($envBin,$periodBin,$f0,$amplitudes)
            $numeric.Harmonics.Invoke($phase,$center,$amplitudes,$window,$grain)
            $numeric.Overlap.Invoke($grain,$center,$window,$synth,$weights)
        }
        $numeric.Normalize.Invoke($synth,$weights)
        $gain=[math]::Sqrt($numeric.Dot.Invoke($stock,$stock)/$numeric.Dot.Invoke($synth,$synth))
        if(-not [double]::IsFinite($gain)){throw 'Nonfinite level match.'}
        $numeric.Scale.Invoke($synth,$gain)
        if(-not [double]::IsFinite([Linq.Enumerable]::Max($synth)) -or -not [double]::IsFinite([Linq.Enumerable]::Min($synth))){throw 'Nonfinite synthesis.'}
        $wav=Join-Path $out ($reference.Name+'-'+$mode+'.wav');Write-CopyWave $wav $synth
        $rms=[double[]]::new($frames);$sumSquared=0.0;$active=0
        $envelopeStockPairs=[double[]]::new(64*$frames);$envelopeSynthPairs=[double[]]::new(64*$frames)
        $stockLog=[double[]]::new($bins);$synthLog=[double[]]::new($bins);$envStockLog=[double[]]::new(64);$envSynthLog=[double[]]::new(64)
        $envSynth=[double[]]::new(64);$gate=[Linq.Enumerable]::Max($stockRms)*0.001
        for($frame=0;$frame -lt $frames;$frame++){
            $numeric.Window.Invoke($synth,$frame*$hop,$window,$grain);Invoke-CopyMatrix $grain $forward $spec
            $numeric.Power.Invoke($spec,$power,2.0/($length*$windowEnergy));$rms[$frame]=[math]::Sqrt([Linq.Enumerable]::Sum($power))
            if($stockRms[$frame] -lt $gate){continue}
            $numeric.Log.Invoke($analysis[$frame].Power,$floorPower,$stockLog);$numeric.Log.Invoke($power,$floorPower,$synthLog)
            $sumSquared+=$numeric.SquaredDistance.Invoke($stockLog,$synthLog)
            [Array]::Clear($bandStats);$numeric.Bands.Invoke($power,0.0,$bandStats)
            for($j=0;$j -lt 64;$j++){$envSynth[$j]=$bandStats[$j]/$envelopeCounts[$j]}
            $numeric.Log.Invoke($analysis[$frame].Envelope,$floorPower,$envStockLog);$numeric.Log.Invoke($envSynth,$floorPower,$envSynthLog)
            [Array]::Copy($envStockLog,0,$envelopeStockPairs,64*$active,64)
            [Array]::Copy($envSynthLog,0,$envelopeSynthPairs,64*$active,64);$active++
        }
        if($active -lt 1){throw 'No active evaluation frames.'}
        $pairedStock=[double[]]::new(64*$active);$pairedSynth=[double[]]::new(64*$active)
        [Array]::Copy($envelopeStockPairs,$pairedStock,$pairedStock.Length);[Array]::Copy($envelopeSynthPairs,$pairedSynth,$pairedSynth.Length)
        $rows.Add([pscustomobject]@{Reference=$reference.Name;Label=$reference.Label;Mode=$mode;Samples=$samples;Frames=$frames;ActiveFrames=$active;
            LsdDb=[math]::Sqrt($sumSquared/($active*$bins));SpectralEnvelopeCorrelation=(Get-CopyCorrelation $pairedStock $pairedSynth);
            TemporalEnvelopeCorrelation=(Get-CopyCorrelation $stockRms $rms);LevelMatchGain=$gain;StockWav=$stockWave;Wav=$wav;
            PcmInput=$reference.Pcm.Path;PcmSHA256=$reference.Pcm.SHA256;F0Input=$reference.Pitch.Path;F0SHA256=$reference.Pitch.SHA256})
        Write-Host "$($reference.Name) $mode LSD=$($rows[-1].LsdDb.ToString('F3')) Envelope=$($rows[-1].SpectralEnvelopeCorrelation.ToString('F4'))"
    }
    if((Get-FileHash -LiteralPath $reference.Pcm.Path).Hash -cne $reference.Pcm.SHA256 -or (Get-FileHash -LiteralPath $reference.Pitch.Path).Hash -cne $reference.Pitch.SHA256){throw 'Read-only input changed during the experiment.'}
}
$receipt=[pscustomobject]@{Status='Passed';BaseCommit=(& git -C $root rev-parse HEAD);SampleRate=$sampleRate;HopSamples=$hop;WindowSamples=$length;EnvelopeBands=64;PeriodicityBands=12;
    ExtraPeach=$extraPeach;NoiseSeed=20261013;NoiseDistribution='Uniform, zero mean, unit variance';FloorDb=-80;ActiveFrameGateDb=-60;
    OriginalPitchRows=$pitchRows;Results=$rows.ToArray();ElapsedSeconds=$clock.Elapsed.TotalSeconds;
    KernelSHA256=(Get-FileHash (Join-Path $PSScriptRoot 'Kokoro.CopySynthesisKernels.psm1')).Hash;HarnessSHA256=(Get-FileHash $PSCommandPath).Hash}
if($LadderReceipt){
    foreach($wave in $baselineHashes.Keys){if((Get-FileHash $wave).Hash -cne $baselineHashes[$wave]){throw 'Run2 audio changed during ladder.'}}
    $receipt|Add-Member Operation 'CopySynthesisLadder';$receipt|Add-Member Run2Receipt $ladderSource
    $receipt|Add-Member Run2ReceiptSHA256 (Get-FileHash $ladderSource).Hash
    $receipt|Add-Member VoicingSource ([pscustomobject]@{Path=$voicingSource;SHA256=$voicingSourceHash;StockCommit='dfb907a02bba8152ca444717ca5d78747ccb4bec';ThresholdHz=$voicedThreshold;
        GeneratorLine='265: harmonic_num=8, voiced_threshod=10)';SineGenLine='139: uv = (f0 > self.voiced_threshold).type(torch.float32)'})
    $receipt|Add-Member SharedAnalysis $sharedAnalysis.ToArray();$receipt|Add-Member Continuity $continuity.ToArray()
    $receipt|Add-Member TimingScope 'Per-reference R1 and R4c times include synthesis, WAV verification, and metrics; shared stock analysis separate. R1 also includes measured harmonic analysis and creation of the residual. R4 reused without rendering. R2 and R3 skipped. No runtime optimization.'
    $receipt|Add-Member Run2Listening 'Copy synthesis: band-limited and distorted, without excessive buzz. Fully voiced control: buzzy as expected.'
    $receipt|Add-Member Run2Continuity ([pscustomobject]@{PhaseResets=$false;ExplicitAmplitudeInterpolation=$false;AmplitudeBlending='Hann overlap-add of frame-constant amplitudes';RawWindowMin=[Linq.Enumerable]::Min($windowSums);RawWindowMax=[Linq.Enumerable]::Max($windowSums);RawWindowMaxDeviation=0.00437113909807341;NormalizedWindowMaxDeviation=0.0})
}
$receipt|Export-Clixml -LiteralPath (Join-Path $out 'receipt.clixml') -Depth 8
$receipt
