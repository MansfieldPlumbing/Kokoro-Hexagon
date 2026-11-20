#requires -Version 7.7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImagePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $ImagePath).Path
$output = [IO.Directory]::CreateDirectory($OutputDirectory).FullName
$null = . "$PSScriptRoot/Invoke-Student.ps1" -Step VerifyComposition

$seed = & $studentOwner {
    param($source)
    $image = Open-StudentImage $source
    # Export only the measured fields reviewed for this seed schema. Free text, paths,
    # filenames, original identifiers, and source fingerprints stay in the private image.
    $groups = @(
        @{ Identity = 'Timing.Zira.WordOnset'; Parent = 'Boundary'; Kind = 'TimingObservation'; Key = @(0, 1, 0, 0); Provenance = 'Zira timing experiment' }
        @{ Identity = 'Timing.Kokoro.MarkFrames'; Parent = 'Boundary'; Kind = 'TimingObservation'; Key = @(0, 1, 0, 0); Provenance = 'Kokoro timing experiment' }
        @{ Identity = 'Performance.Generated.Acoustics'; Parent = 'Occurrence'; Kind = 'RecordingObservation'; Key = @(0, 0, 0, 0); Provenance = 'Generated acoustic experiment' }
        @{ Identity = 'Performance.Generated.HeartReading.Alignment'; Parent = 'Occurrence'; Kind = 'RecordingObservation'; Key = @(0, 0, 0, 0); Provenance = 'Generated paragraph alignment experiment' }
    )
    function Read-OptionalNumber($value) {
        if ($null -eq $value) { return }
        # Existing checkpoints can represent a missing pipeline value as an empty member bag.
        if ($value -is [pscustomobject] -and !@($value.PSObject.Properties).Count) { return }
        [double]$value
    }
    $records = @(foreach ($group in $groups) {
        $node = $image.Percepts[$group.Identity]
        if (!$node) { continue }
        $index = 0
        foreach ($record in $node.Examples) {
            $index++
            $value = $record.Measured
            $condition = ''
            $measurement = switch ($group.Identity) {
                'Timing.Zira.WordOnset' {
                    if ($record.Condition -ceq 'HeldOutWordOnsetDeltaMilliseconds') {
                        $condition = 'Held-out word onset delta'
                        [ordered]@{ AddedFrames = [double]$value.AddedFrames; HeldOutMAEms = [double]$value.HeldOutMAEms; ZeroEffectMAEms = [double]$value.ZeroEffectMAEms }
                    } else {
                        if ($record.Condition -cnotin ',', ':', '.') { throw 'Unexpected Zira punctuation.' }
                        $condition = $record.Condition
                        [double]$value
                    }
                }
                'Timing.Kokoro.MarkFrames' {
                    if ($record.Condition -cnotin 'Fit', 'Test') { throw 'Unexpected Kokoro split.' }
                    $condition = $record.Condition
                    [int]$value
                }
                'Performance.Generated.Acoustics' {
                    $condition = 'Audio-only measurement'
                    [ordered]@{
                        MedianF0Hz = Read-OptionalNumber $value.MedianF0Hz
                        FrameHop = [int]$value.FrameHop; AnalysisRate = [int]$value.AnalysisRate
                        Gaps = @(foreach ($gap in $value.Gaps) {
                            [ordered]@{
                                FirstFrame = [int]$gap.FirstFrame; Frames = [int]$gap.Frames; Seconds = [double]$gap.Seconds
                                Internal = [bool]$gap.Internal
                                PreGapSlopeSemitonesPerSecond = Read-OptionalNumber $gap.PreGapSlopeSemitonesPerSecond
                                PitchResetSemitones = Read-OptionalNumber $gap.PitchResetSemitones
                            }
                        })
                    }
                }
                'Performance.Generated.HeartReading.Alignment' {
                    $condition = 'Unreviewed word alignment'
                    [ordered]@{
                        DurationSeconds = [double]$value.Alignment.DurationSeconds
                        Words = @(foreach ($word in $value.Alignment.Words) {
                            [ordered]@{
                                StartMs = [double]$word.StartMs; EndMs = [double]$word.EndMs
                                StartShiftMs = [double]$word.StartShiftMs; EndShiftMs = [double]$word.EndShiftMs
                                MedianF0Hz = Read-OptionalNumber $word.MedianF0Hz
                            }
                        })
                        Boundaries = @(foreach ($boundary in $value.Alignment.Boundaries) {
                            [ordered]@{
                                Index = [int]$boundary.Index
                                TagCount = @($boundary.Tags | Where-Object { $_ }).Count
                                Mark = if ($boundary.Mark -cin ',', ':', '.', '?', '!', ';') { $boundary.Mark }
                                StartMs = Read-OptionalNumber $boundary.StartMs
                                EndMs = Read-OptionalNumber $boundary.EndMs
                                QuietRmsMs = Read-OptionalNumber $boundary.QuietRmsMs
                                PitchChangeSemitones = Read-OptionalNumber $boundary.PitchChangeSemitones
                                WarpShiftMs = [double]$boundary.WarpShiftMs
                                CollapsedNeighbor = [bool]$boundary.CollapsedNeighbor
                            }
                        })
                    }
                }
            }
            [ordered]@{
                Identity = "seed-v1/$($group.Identity)/$index"; Percept = $group.Identity; Occurrence = "sample-$index"
                Provenance = $group.Provenance; Condition = $condition; Measured = $measurement
            }
        }
    })
    if (!$records.Count) { throw 'The image has no supported seed evidence.' }
    [ordered]@{
        SchemaVersion = 1
        Percepts = @($groups | Where-Object { $image.Percepts.ContainsKey($_.Identity) } |
            ForEach-Object { [ordered]@{ Identity = $_.Identity; Kind = $_.Kind; Key = $_.Key; Parent = $_.Parent } })
        Evidence = $records
    }
} $source

$jsonPath = Join-Path $output 'percept-seed.v1.json'
$seed | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$project = Join-Path $PSScriptRoot 'PerceptSeed/PerceptSeed.csproj'
$artifacts = Join-Path $output 'build'
& dotnet build $project --configuration Release --artifacts-path $artifacts --output $output "-p:PerceptSeedPath=$jsonPath"
if ($LASTEXITCODE) { throw "Managed seed build failed with exit code $LASTEXITCODE." }
$dll = Join-Path $output 'Kokoro.Student.PerceptSeed.dll'
[pscustomobject]@{ Path = $dll; SHA256 = (Get-FileHash -LiteralPath $dll).Hash; Evidence = $seed.Evidence.Count }
