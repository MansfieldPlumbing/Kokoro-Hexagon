using module ./StudentTeacherObservation.psm1
#requires -Version 7.7
param(
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank'),
    [string] $SourceIdentity='Gutenberg/11',
    [int[]] $Offset,
    [switch] $VerifyBuffers
)
$ErrorActionPreference='Stop'
$field=& "$PSScriptRoot/Open-StudentSpeechInvestigation.ps1" -BankPath $BankPath -SourceIdentity $SourceIdentity
$checked=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($comparison in $field.Comparisons) {
    $teacher=$comparison.Teacher
    if ($null -ne $Offset -and $teacher.Start -notin $Offset) { continue }
    foreach ($execution in $teacher.StockExecution,$teacher.ProceduralExecution) {
        if (!$execution) { continue }
        if (![object]::ReferenceEquals($execution.Teacher,$teacher) -or
            ![object]::ReferenceEquals($teacher.Document.Source,$field.Inventory.Units[$teacher.Document.Source.Id])) {
            throw 'Broken source reference identity.'
        }
        if ($comparison.HumanContext -and ![object]::ReferenceEquals($comparison.HumanContext.Document,$teacher.Document)) {
            throw 'Human evidence does not share the original document.'
        }
        $byStage=[Collections.Generic.Dictionary[string,StudentStockActivation]]::new([StringComparer]::Ordinal)
        foreach ($a in $execution.Activations) {
            if (![object]::ReferenceEquals($a.Execution,$execution)) { throw 'Broken activation owner reference.' }
            $byStage.Add($a.Stage,$a)
            if ($VerifyBuffers -and $checked.Add("$($a.TypeCode):$($a.Checksum)")) {
                $values=$a.Read()
                if ($values.Length -ne $a.Count -or $values -is [object[]]) { throw 'Buffer did not restore its numeric CLR array.' }
            }
        }
        $generatorInput=$byStage['decoder.generator_input']
        $wave=$byStage['generator.waveform']
        if ($generatorInput.Count -ne $generatorInput.Extent * 512 -or $wave.Count -ne 300 * $generatorInput.Extent) {
            throw 'Generator input is not 512 channels on the 80 Hz clock.'
        }
        $generatorClock=$generatorInput.FrameClock()
        $stftClock=$byStage['generator.source.stft'].FrameClock()
        $postClock=$byStage['decoder.module.generator.conv_post'].FrameClock()
        $tickStarts=$execution.TokenTickStarts()
        if ($generatorClock.SamplesPerFrame -ne 300 -or $stftClock.SamplesPerFrame -ne 5 -or $stftClock.ReflectedPrefixFrames -ne 0 -or
            $postClock.FrameCount -ne 60*$generatorInput.Extent+1 -or $postClock.ReflectedPrefixFrames -ne 1 -or
            $tickStarts[-1] -ne $generatorInput.Extent) { throw 'Inconsistent source, generator, or token clocks.' }
        foreach ($conv in $execution.Convolutions) {
            if (![object]::ReferenceEquals($conv.Geometry.Execution,$execution) -or
                ![object]::ReferenceEquals($conv.Output.Execution,$execution)) { throw 'Broken convolution reference identity.' }
            $null=$conv.InputFramesForOutput(0)
        }
        $procedural=[object]::ReferenceEquals($execution,$teacher.ProceduralExecution)
        $sites=@($execution.Activations | Where-Object Stage -CLike '*.parameters')
        $generator=@($sites | Where-Object Stage -CLike 'decoder.module.generator.*').Count
        $predictor=@($sites | Where-Object Stage -CLike 'predictor.module.*').Count
        $decoder=$sites.Count-$generator-$predictor
        $attention=@($execution.Activations | Where-Object Stage -CLike 'albert.*.attention.weights').Count
        if ($generator -ne 48 -or $decoder -ne 10 -or (!$procedural -and ($predictor -ne 12 -or $attention -ne 12))) {
            throw 'Unexpected deployed AdaIN or ALBERT site inventory.'
        }
        foreach ($site in $sites) {
            $prefix=$site.Stage.Substring(0,$site.Stage.Length-'.parameters'.Length)
            $input=$byStage["$prefix.input"]
            $output=$byStage["$prefix.output"]
            if ($site.Count -ne 11*$site.Extent -or $input.Count -ne $output.Count -or $input.Extent -ne $output.Extent -or
                $input.Count -ne $site.Extent*$input.Extent) {
                throw "Inconsistent normalization scope for $prefix."
            }
        }
        $words=$teacher.WordOccurrenceIndices.Count
        "source=$($teacher.Document.Source.Id) offset=$($teacher.Start) procedural=$procedural words=$words samples=$($wave.Count) stages=$($byStage.Count) albert=$attention adain=$predictor/$decoder/$generator channels=512 humanAnchors=$($comparison.HumanWordAnchors.Count)"
        if ($execution.FrontStateReplay) {
            $replay=$execution.FrontStateReplay
            if (![object]::ReferenceEquals($replay.Teacher,$teacher)) { throw 'Front replay lost its teacher reference.' }
            $recurrences=@($replay.Activations | Where-Object Stage -CLike '*.state_trace')
            if ($recurrences.Count -ne 6) { throw 'Unexpected front replay recurrent stage count.' }
            foreach ($recurrent in $recurrences) {
                $shape=$recurrent.Shape()
                if ($shape.Length -ne 4 -or $shape[0] -ne 2 -or $shape[2] -ne 6 -or $recurrent.Count -ne 12*$shape[1]*$shape[3]) {
                    throw 'Unexpected recurrent gate and state geometry.'
                }
            }
            if ($VerifyBuffers) {
                foreach ($activation in $replay.Activations) {
                    if ($checked.Add("$($activation.TypeCode):$($activation.Checksum)")) { $null=$activation.Read() }
                }
            }
            "source=$($teacher.Document.Source.Id) offset=$($teacher.Start) frontReplay=$($replay.Activations.Count) recurrent=$($recurrences.Count)"
        }
    }
    foreach ($experiment in $teacher.ResidualInterventions) {
        if (![object]::ReferenceEquals($experiment.Baseline,$teacher.StockExecution) -or
            ![object]::ReferenceEquals($experiment.Outcome.Teacher,$teacher)) { throw 'Broken intervention reference identity.' }
        if ($VerifyBuffers) {
            foreach ($activation in $experiment.Outcome.Activations) {
                if ($checked.Add("$($activation.TypeCode):$($activation.Checksum)")) { $null=$activation.Read() }
            }
        }
        "source=$($teacher.Document.Source.Id) offset=$($teacher.Start) residual=$($experiment.Site) waveformChanged=$($experiment.ChangedWaveform()) baselineInput=$($experiment.Baseline.GeneratorInput.Checksum)"
    }
}
if ($VerifyBuffers) { "verifiedDistinctTypedBuffers=$($checked.Count)" }
