class StudentSeedPrompt {
    [int] $Id
}

class StudentSeedTag {
    [int] $Id
}

class StudentSeedTransferRow {
    [StudentSeedPrompt] $Prompt
    [double] $DeltaMs
}

class StudentSeedTransfer {
    [int] $AddedFrames
    [double] $HeldOutMAEms
    [double] $ZeroEffectMAEms
    [int] $Samples
    [StudentSeedTransferRow[]] $Fit
    [StudentSeedTransferRow[]] $Test
}

class StudentSeedGap {
    [int] $FirstFrame
    [int] $Frames
    [double] $Seconds
    [bool] $Internal
    [Nullable[double]] $PreGapSlopeSemitonesPerSecond
    [Nullable[double]] $PitchResetSemitones
}

class StudentSeedAcoustics {
    [Nullable[double]] $MedianF0Hz
    [int] $FrameHop
    [int] $AnalysisRate
    [StudentSeedGap[]] $Gaps
}

class StudentSeedWord {
    [double] $StartMs
    [double] $EndMs
    [double] $StartShiftMs
    [double] $EndShiftMs
    [Nullable[double]] $MedianF0Hz
}

class StudentSeedBoundary {
    [int] $Index
    [StudentSeedWord] $Previous
    [StudentSeedWord] $Next
    [StudentSeedTag[]] $Tags
    [string] $Mark
    [Nullable[double]] $QuietRmsMs
    [Nullable[double]] $PitchChangeSemitones
    [double] $WarpShiftMs
    [bool] $CollapsedNeighbor
}

class StudentSeedAlignment {
    [double] $DurationSeconds
    [StudentSeedWord[]] $Words
    [StudentSeedBoundary[]] $Boundaries
}

class StudentSeedObservation {
    [string] $Identity
    [string] $Condition
    [StudentSeedPrompt] $Prompt
    [string] $Mark
    [Nullable[double]] $OnsetMilliseconds
    [Nullable[int]] $Frames
    [StudentSeedTransfer] $Transfer
    [StudentSeedAcoustics] $Acoustics
    [StudentSeedAlignment] $Alignment
}

class StudentSeedPercept {
    [string] $Identity
    [string] $Kind
    [float[]] $Key
    [StudentSeedPercept] $Parent
    [StudentSeedPercept[]] $Children
    [StudentSeedObservation[]] $Examples
}

class StudentPerceptSeed {
    [StudentSeedPercept] $Occurrence
    [StudentSeedPercept[]] $Percepts
    [StudentSeedObservation[]] $Evidence

    static [StudentPerceptSeed] $Seed

    static [StudentPerceptSeed] Read() {
        return [StudentPerceptSeed]::Seed
    }
}
