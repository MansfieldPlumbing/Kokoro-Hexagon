using module ./StudentTeacherObservation.psm1
#requires -Version 7.7
param(
    [string] $BankPath=(Join-Path $PSScriptRoot '../data/source-bank'),
    [string] $SourceIdentity='Gutenberg/11',
    [switch] $VerifyBuffers
)
$ErrorActionPreference='Stop'
$field=& "$PSScriptRoot/Open-StudentSpeechInvestigation.ps1" -BankPath $BankPath -SourceIdentity $SourceIdentity
$checked=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($comparison in $field.Comparisons) {
    $teacher=$comparison.Teacher
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
            if ($VerifyBuffers -and $checked.Add("$($a.TypeCode):$($a.Checksum)")) { $null=$a.Read() }
        }
        $generatorInput=$byStage['decoder.generator_input']
        $wave=$byStage['generator.waveform']
        if ($generatorInput.Count -ne $generatorInput.Extent * 512 -or $wave.Count -ne 300 * $generatorInput.Extent) {
            throw 'Generator input is not 512 channels on the 80 Hz clock.'
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
        $words=0
        for ($i=0;$i -lt $teacher.Document.OriginalSpans.Length;$i+=2) {
            $at=$teacher.Document.OriginalSpans[$i]
            if ($at -ge $teacher.Start -and $at -lt $teacher.Start+$teacher.Length) { $words++ }
        }
        "source=$($teacher.Document.Source.Id) offset=$($teacher.Start) procedural=$procedural words=$words samples=$($wave.Count) stages=$($byStage.Count) albert=$attention adain=$predictor/$decoder/$generator channels=512 humanAnchors=$($comparison.HumanWordAnchors.Count)"
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
