#requires -Version 7.4
<#
.SYNOPSIS
    Consolidated, bounded relational percept-acquisition instrument (SMA / CoreCLR / PSC).
.DESCRIPTION
    Dot-source with -Library to use typed borrowed views over the existing bank.
    Run without arguments for full synthetic acquisition, disequilibrium, accommodation,
    strict lowering-parity, weak-rematerialization, reverie-wake, external delegate hook,
    and full evidentiary PSNL reconstruction tests.
    Provisional research machinery. No private bank writes, no JSON/CLIXML, no Add-Type.
    Real candidates require the existing independent judge and provenance audit; statistical
    nomination never automatically publishes a percept.
#>
[CmdletBinding()]
param([switch]$Library)

# ==============================================================================
# 1. Core Identity, Weak Attachments, Reproducible Handles & Source-Clean Refs
# ==============================================================================
class HuntSourceCleanReference {
    [string] $OriginalTypeName
    [long] $ClrIdentityHash
    [string] $SourceKey
    HuntSourceCleanReference([string]$typeName, [long]$hash, [string]$key) {
        $this.OriginalTypeName = $typeName
        $this.ClrIdentityHash = $hash
        $this.SourceKey = $key
    }
}

class HuntAxis {
    [guid] $Identity = [guid]::NewGuid()
    [object] $SemanticMember       # Actual MemberInfo, AST, tensor descriptor, measure, etc.
    [string] $Name                 # display only
    [string] $Units                # display/measurement contract, not a type substitute
}

class HuntPredictiveScalar {
    [int] $Value
    HuntPredictiveScalar([int]$value) { $this.Value=$value }
}
class HuntOrigin {
    [object] $Source               # Actual source object/identity (not a copy of its values)
    [object] $EvidenceFamily       # audited shared provenance identity; not a sampling block
}
class HuntBlock {
    [object] $Owner                # actual independent experimental/sampling unit
    [string] $Identity             # diagnostic, stable across reopen for adapter checks
    [HuntOrigin[]] $Roots = @()    # ALL transitive roots, not derived views/replays
}
class HuntReading {
    [HuntAxis] $Axis
    [object] $Observation          # original typed observation / recoverable tensor handle
    [object] $Coordinate           # verified alignment on original clock/semantic referent
    [double] $Value
}
class HuntCase {
    [object] $Referent
    [object] $Context              # typed identity, e.g. acquired context / CLR enum value
    [HuntBlock] $Block
    [HuntReading[]] $Readings = @()
    [bool] $Synthetic
    [HuntReading] Find([HuntAxis] $Axis) {
        foreach ($reading in $this.Readings) {
            if ([object]::ReferenceEquals($reading.Axis, $Axis)) { return $reading }
        }
        return $null
    }
}

class HuntSemanticAttachment {
    [long] $ClrIdentityHash
    [System.Collections.Generic.List[string]] $SemanticTypeNames = [System.Collections.Generic.List[string]]::new()
    [System.Collections.Generic.HashSet[string]] $Roles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [System.Collections.Generic.List[object]] $Patterns = [System.Collections.Generic.List[object]]::new()
    [System.Collections.Generic.List[object]] $Reveries = [System.Collections.Generic.List[object]]::new()
}

class HuntReproducibleHandle {
    [string] $Pin
    [WeakReference[object]] $WeakTarget
    [scriptblock] $Rematerializer
    HuntReproducibleHandle([string]$pin, [object]$target, [scriptblock]$rematerializer) {
        $this.Pin = $pin
        $this.WeakTarget = [WeakReference[object]]::new($target)
        $this.Rematerializer = $rematerializer
    }
    [object[]] GetOrRematerialize() {
        [object]$target = $null
        if ($this.WeakTarget.TryGetTarget([ref]$target) -and $null -ne $target) {
            return @($target, $false)
        }
        $rebuilt = & $this.Rematerializer
        $this.WeakTarget.SetTarget($rebuilt)
        return @($rebuilt, $true)
    }
}

# ==============================================================================
# 2. 3-Tier Execution Model, Lowerable `When` Clauses, Judgments & Patterns
# ==============================================================================
enum HuntExecutionTier { ReflectiveSma; CompiledExpression; ExternalDelegate }
enum HuntReliance { Proposed; Nominated; SyntheticAdmitted; Demoted; Insufficient; ObservedScope }

class HuntWhenClause {
    [string] $MemberName
    [System.Reflection.MemberInfo] $SemanticMember
    [string] $Operator             # '>=', '<=', '==', '!='
    [object] $Value
    HuntWhenClause([string]$memberName, [System.Reflection.MemberInfo]$member, [string]$op, [object]$val) {
        $this.MemberName = $memberName
        $this.SemanticMember = $member
        $this.Operator = $op
        $this.Value = $val
    }
}

class HuntJudgment {
    [long] $Version
    [datetime] $At
    [HuntReliance] $Reliance
    [double] $P = [double]::NaN
    [double] $AdjustedP = [double]::NaN
    [int] $IndependentBlocks
    [int] $Wins
    [int] $Losses
    [int] $Ties
    [int] $OutsideBound
    [int] $MissingOutcomes
    [int] $OriginFamilies
    [double] $Alpha
    [HuntCase[]] $Evidence = @()
    [string] $Reason
    [HuntJudgment] $Trigger
}

class HuntPattern {
    [guid] $Identity = [guid]::NewGuid()
    [HuntAxis] $InputAxis
    [HuntAxis] $OutputAxis
    [object] $Context
    [bool] $Scoped
    [object[]] $ObservedContexts = @()
    [HuntWhenClause[]] $WhenGuards = @()
    [double] $Slope
    [double] $Offset
    [double] $Baseline
    [double] $Tolerance
    [HuntCase[]] $Discovery = @()
    [HuntPattern] $Predecessor
    [HuntPattern[]] $Constituents = @()
    [HuntJudgment[]] $ConstituentJudgments = @()
    hidden [bool] $DependenciesValid = $true
    [System.Collections.Generic.List[HuntPattern]] $Dependents = [System.Collections.Generic.List[HuntPattern]]::new()
    [HuntJudgment] $Current
    [System.Collections.Generic.List[HuntJudgment]] $History = [System.Collections.Generic.List[HuntJudgment]]::new()
    [System.Collections.Generic.List[HuntCase]] $Counterexamples = [System.Collections.Generic.List[HuntCase]]::new()
    [bool] $Synthetic

    # Tier-2 / Tier-3 Lowering + Strict Equivalence Verification
    [HuntExecutionTier] $ExecutionTier = [HuntExecutionTier]::ReflectiveSma
    [Func[object, double]] $LoweredEvaluator
    [Func[object, bool]] $LoweredGuard
    [bool] $LoweredReady = $false
    [int] $LoweredVerifiedCases = 0

    [bool] DependenciesCurrent() { return $this.DependenciesValid }
    [void] ForceDependenciesValid([bool]$valid) { $this.DependenciesValid = $valid }
    [void] RegisterDependent([HuntPattern]$Child) {
        if (!$this.Dependents.Contains($Child)) { $this.Dependents.Add($Child) }
    }
    [bool] Applies([HuntCase] $Case) {
        if ($Case.Synthetic -ne $this.Synthetic) { return $false }
        $ctxOk = $false
        if ($this.Scoped) { $ctxOk = [object]::Equals($this.Context, $Case.Context) }
        else {
            foreach ($ctx in $this.ObservedContexts) {
                if ([object]::Equals($ctx, $Case.Context)) { $ctxOk = $true; break }
            }
        }
        if (!$ctxOk) { return $false }
        if ($this.WhenGuards.Count -gt 0 -and $null -ne $Case.Referent) {
            foreach ($g in $this.WhenGuards) {
                $val = $Case.Referent.($g.MemberName)
                $pass = switch ($g.Operator) {
                    '>=' { [double]$val -ge [double]$g.Value }
                    '<=' { [double]$val -le [double]$g.Value }
                    '==' { [object]::Equals($val, $g.Value) }
                    '!=' { ![object]::Equals($val, $g.Value) }
                    default { $false }
                }
                if (!$pass) { return $false }
            }
        }
        return $true
    }
    [double] Evaluate([double] $X) { return $this.Slope * $X + $this.Offset }
    [double] EvaluateProjected([int]$value) {
        if ($this.Synthetic -or !$this.LoweredReady -or !$this.DependenciesValid) { throw 'No current real scalar evaluator.' }
        return $this.LoweredEvaluator.Invoke([HuntPredictiveScalar]::new($value))
    }

    [bool] VerifyLoweredDelegate([Func[object, double]]$CandidateEval, [Func[object, bool]]$CandidateGuard, [HuntCase[]]$ParityCohort, [type]$DeclaringType) {
        if ($null -eq $CandidateEval -or $null -eq $ParityCohort -or $ParityCohort.Count -eq 0) { return $false }
        $verified = 0
        foreach ($c in $ParityCohort) {
            if ($null -eq $c.Referent -or $c.Referent.GetType() -ne $DeclaringType) { return $false }
            $r = $c.Find($this.InputAxis)
            if ($null -eq $r) { return $false }
            $refY = $this.Evaluate($r.Value)
            $lowY = $CandidateEval.Invoke($c.Referent)
            if (![double]::IsFinite($lowY) -or [Math]::Abs($lowY - $refY) -gt 1e-12) { return $false }
            if ($null -ne $CandidateGuard) {
                $refG = $true
                foreach ($g in $this.WhenGuards) {
                    $v = $c.Referent.($g.MemberName)
                    $ok = switch ($g.Operator) {
                        '>=' { [double]$v -ge [double]$g.Value }
                        '<=' { [double]$v -le [double]$g.Value }
                        '==' { [object]::Equals($v, $g.Value) }
                        '!=' { ![object]::Equals($v, $g.Value) }
                    }
                    if (!$ok) { $refG = $false; break }
                }
                if ($CandidateGuard.Invoke($c.Referent) -ne $refG) { return $false }
            }
            $verified++
        }
        if ($verified -ne $ParityCohort.Count) { return $false }
        $this.LoweredVerifiedCases = $verified
        return $true
    }

    [bool] TryCompileAndVerifyLowered([HuntCase[]]$ParityCohort) {
        $this.LoweredEvaluator = $null
        $this.LoweredGuard = $null
        $this.LoweredReady = $false
        $this.LoweredVerifiedCases = 0
        $this.ExecutionTier = [HuntExecutionTier]::ReflectiveSma
        if (!$this.DependenciesValid -or $null -eq $ParityCohort -or $ParityCohort.Count -eq 0) { return $false }
        # The real evaluator receives only a scalar projection. Original evidence remains in
        # adjudication and is never the object argument of the compiled delegate.
        if (!$this.Synthetic -and $this.WhenGuards.Count) { return $false }
        $mem = if ($this.Synthetic) {
            $this.InputAxis.SemanticMember -as [System.Reflection.MemberInfo]
        } else {
            [HuntPredictiveScalar].GetProperty('Value')
        }
        if ($null -eq $mem -or $null -eq $mem.DeclaringType) { return $false }
        $declType = $mem.DeclaringType

        $pObj = [System.Linq.Expressions.Expression]::Parameter([object], 'referent')
        $castExpr = [System.Linq.Expressions.Expression]::Convert($pObj, $declType)
        $memExpr = [System.Linq.Expressions.Expression]::MakeMemberAccess($castExpr, $mem)
        $asDouble = if ($memExpr.Type -eq [double]) { $memExpr } else { [System.Linq.Expressions.Expression]::Convert($memExpr, [double]) }
        $affineExpr = [System.Linq.Expressions.Expression]::Add(
            [System.Linq.Expressions.Expression]::Multiply($asDouble, [System.Linq.Expressions.Expression]::Constant($this.Slope, [double])),
            [System.Linq.Expressions.Expression]::Constant($this.Offset, [double])
        )
        $compiledEval = [System.Linq.Expressions.Expression]::Lambda(
            [Func[object, double]],
            $affineExpr,
            [System.Linq.Expressions.ParameterExpression[]]@($pObj)
        ).Compile()

        [Func[object, bool]]$compiledGuard = $null
        if ($this.WhenGuards.Count -gt 0) {
            [System.Linq.Expressions.Expression]$acc = $null
            foreach ($g in $this.WhenGuards) {
                $gm = $g.SemanticMember
                if ($null -eq $gm -or $gm.DeclaringType -ne $declType) { return $false }
                $gAccess = [System.Linq.Expressions.Expression]::MakeMemberAccess($castExpr, $gm)
                $cmp = switch ($g.Operator) {
                    '>=' {
                        $lhs = if ($gAccess.Type -eq [double]) { $gAccess } else { [System.Linq.Expressions.Expression]::Convert($gAccess, [double]) }
                        [System.Linq.Expressions.Expression]::GreaterThanOrEqual($lhs, [System.Linq.Expressions.Expression]::Constant([double]$g.Value, [double]))
                    }
                    '<=' {
                        $lhs = if ($gAccess.Type -eq [double]) { $gAccess } else { [System.Linq.Expressions.Expression]::Convert($gAccess, [double]) }
                        [System.Linq.Expressions.Expression]::LessThanOrEqual($lhs, [System.Linq.Expressions.Expression]::Constant([double]$g.Value, [double]))
                    }
                    '==' {
                        $typedC = [Convert]::ChangeType($g.Value, $gAccess.Type)
                        [System.Linq.Expressions.Expression]::Equal($gAccess, [System.Linq.Expressions.Expression]::Constant($typedC, $gAccess.Type))
                    }
                    '!=' {
                        $typedC = [Convert]::ChangeType($g.Value, $gAccess.Type)
                        [System.Linq.Expressions.Expression]::NotEqual($gAccess, [System.Linq.Expressions.Expression]::Constant($typedC, $gAccess.Type))
                    }
                    default { return $false }
                }
                $acc = if ($null -eq $acc) { $cmp } else { [System.Linq.Expressions.Expression]::AndAlso($acc, $cmp) }
            }
            $compiledGuard = [System.Linq.Expressions.Expression]::Lambda(
                [Func[object, bool]],
                $acc,
                [System.Linq.Expressions.ParameterExpression[]]@($pObj)
            ).Compile()
        }

        if (!$this.VerifyLoweredDelegate($compiledEval, $compiledGuard, $ParityCohort, $declType)) {
            $this.LoweredVerifiedCases = 0
            return $false
        }
        $this.LoweredEvaluator = $compiledEval
        $this.LoweredGuard = $compiledGuard
        $this.LoweredReady = $true
        $this.ExecutionTier = [HuntExecutionTier]::CompiledExpression
        return $true
    }

    [double] EvaluateFast([HuntCase]$Case, [HuntReading]$Reading) {
        if ($this.LoweredReady -and $null -ne $this.LoweredEvaluator -and $this.DependenciesValid -and $null -ne $Case.Referent) {
            return $this.LoweredEvaluator.Invoke($Case.Referent)
        }
        return $this.Evaluate($Reading.Value)
    }

    hidden [void] RecordLocal([HuntJudgment]$Judgment) {
        $Judgment.Version = $this.History.Count + 1
        if ($Judgment.At -eq [datetime]::MinValue) { $Judgment.At = [datetime]::UtcNow }
        $this.History.Add($Judgment)
        $this.Current = $Judgment
        if ($Judgment.Reliance -eq [HuntReliance]::Demoted) {
            $this.LoweredReady = $false
            $this.LoweredVerifiedCases = 0
            $this.ExecutionTier = [HuntExecutionTier]::ReflectiveSma
        }
    }
    [void] Record([HuntJudgment] $Judgment) {
        $this.RecordLocal($Judgment)
        $pending = [System.Collections.Generic.Queue[HuntPattern]]::new()
        $seen = [System.Collections.Generic.HashSet[HuntPattern]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
        foreach ($child in $this.Dependents) { $pending.Enqueue($child) }
        while ($pending.Count) {
            $child = $pending.Dequeue()
            if (!$seen.Add($child)) { continue }
            if ($child.DependenciesValid) {
                $child.DependenciesValid = $false
                $consequence = [HuntJudgment]::new()
                $consequence.Reliance = [HuntReliance]::Demoted
                $consequence.Reason = 'Derived recognizer withdrawn because a constituent judgment changed; direct historical evidence remains and may support independent reacquisition'
                $consequence.Trigger = $Judgment
                $child.RecordLocal($consequence)
            }
            foreach ($next in $child.Dependents) { $pending.Enqueue($next) }
        }
    }
}

# ==============================================================================
# 3. Predictions, Outcomes, Trials, Reveries & Session (with Tier-3 PSC Hook)
# ==============================================================================
class HuntPrediction {
    [HuntPattern] $Pattern
    [HuntCase] $Input
    [HuntReading] $InputReading
    [HuntJudgment] $Judgment
    [double] $Expected
    [datetime] $At
    [bool] IsCurrent() { return [object]::ReferenceEquals($this.Judgment, $this.Pattern.Current) -and $this.Pattern.DependenciesCurrent() }
}
class HuntOutcome {
    [HuntPrediction] $Prediction
    [HuntReading] $Actual
    [double] $Error
    [bool] $OutsideBound
}
class HuntTrial {
    [HuntPattern] $Pattern
    [HuntPrediction[]] $Predictions = @()
    [HuntOutcome[]] $Outcomes = @()
    [bool] $Closed
}
class HuntReverie {
    [guid] $Identity = [guid]::NewGuid()
    [HuntPattern] $Pattern
    [string] $Status = 'DormantCooldown'
    [string] $CooldownReason
    [System.Collections.Generic.HashSet[HuntAxis]] $WakeAxes = [System.Collections.Generic.HashSet[HuntAxis]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    [System.Collections.Generic.HashSet[string]] $WakeCapabilities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [double] $Heat = 1.0
}
class HuntSession {
    [double] $FamilyAlpha = 0.00269979606326019 # two-sided normal 3-sigma reference; strict <
    [int] $Epoch
    [bool] $Synthetic
    [System.Runtime.CompilerServices.ConditionalWeakTable[object, HuntSemanticAttachment]] $Attachments = [System.Runtime.CompilerServices.ConditionalWeakTable[object, HuntSemanticAttachment]]::new()
    [System.Collections.Generic.HashSet[string]] $Consumed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [System.Collections.Generic.HashSet[object]] $ConsumedOwners = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    [System.Collections.Generic.List[HuntPattern]] $Patterns = [System.Collections.Generic.List[HuntPattern]]::new()
    [System.Collections.Generic.List[HuntOutcome]] $Outcomes = [System.Collections.Generic.List[HuntOutcome]]::new()
    [System.Collections.Generic.List[HuntTrial]] $Trials = [System.Collections.Generic.List[HuntTrial]]::new()
    [System.Collections.Generic.List[HuntReverie]] $Reveries = [System.Collections.Generic.List[HuntReverie]]::new()
    [System.Collections.Generic.HashSet[string]] $Capabilities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [scriptblock] $PscLowererHook   # Optional Tier-3 PSC IL emitter: { param([HuntPattern]$p) ... returns Func[object,double] }
    [HuntSemanticAttachment] Attach([object]$Referent) {
        $att = $this.Attachments.GetOrCreateValue($Referent)
        if ($att.SemanticTypeNames.Count -eq 0) {
            $att.ClrIdentityHash = [long][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Referent)
            foreach ($tn in $Referent.PSObject.TypeNames) {
                if ($tn -ne 'System.Object') { $att.SemanticTypeNames.Add($tn) }
            }
        }
        return $att
    }
    [double] NextAlpha() {
        $this.Epoch++
        return $this.FamilyAlpha * [Math]::Pow(0.5, $this.Epoch)
    }
}

function Initialize-HuntEts {
    if (Get-Variable HuntEtsInitialized -Scope Script -ErrorAction SilentlyContinue) { return }
    Update-TypeData -TypeName 'HuntSession' -MemberType ScriptMethod -MemberName 'OpenPerceptField' -Force -Value {
        $admitted = 0; $demoted = 0; $lowered = 0; $pscTier = 0
        foreach ($p in $this.Patterns) {
            if ($null -ne $p.Current) {
                if ($p.Current.Reliance -eq [HuntReliance]::SyntheticAdmitted -or $p.Current.Reliance -eq [HuntReliance]::Nominated) { $admitted++ }
                elseif ($p.Current.Reliance -eq [HuntReliance]::Demoted) { $demoted++ }
            }
            if ($p.LoweredReady) { $lowered++ }
            if ($p.ExecutionTier -eq [HuntExecutionTier]::ExternalDelegate) { $pscTier++ }
        }
        $dormant = 0; foreach ($r in $this.Reveries) { if ($r.Status -eq 'DormantCooldown') { $dormant++ } }
        [pscustomobject]@{
            Epoch            = $this.Epoch
            Synthetic        = $this.Synthetic
            TotalPatterns    = $this.Patterns.Count
            AdmittedOrNom    = $admitted
            Demoted          = $demoted
            LoweredDelegates = $lowered
            ExternalDelegate     = $pscTier
            DormantReveries  = $dormant
            Capabilities     = $this.Capabilities.Count
        }
    }
    $script:HuntEtsInitialized = $true
}
if (!$Library) { Initialize-HuntEts }

function Register-HuntPscLowerer {
    param([Parameter(Mandatory)][HuntSession]$Session, [Parameter(Mandatory)][scriptblock]$Emitter)
    $Session.PscLowererHook = $Emitter
}

function Promote-HuntPatternToPsc {
    param([Parameter(Mandatory)][HuntSession]$Session, [Parameter(Mandatory)][HuntPattern]$Pattern, [Parameter(Mandatory)][HuntCase[]]$ParityCohort)
    if ($null -eq $Session.PscLowererHook) { return $false }
    if (!$Pattern.Synthetic) { return $false } # Unrestricted external callbacks are fixture-only.
    if (!$Pattern.DependenciesCurrent() -or $Pattern.Current.Reliance -eq [HuntReliance]::Demoted) { return $false }
    $mem = $Pattern.InputAxis.SemanticMember -as [System.Reflection.MemberInfo]
    if ($null -eq $mem -or $null -eq $mem.DeclaringType) { return $false }
    $pscDelegate = (& $Session.PscLowererHook $Pattern) -as [Func[object, double]]
    if ($null -eq $pscDelegate) { return $false }
    if (!$Pattern.VerifyLoweredDelegate($pscDelegate, $Pattern.LoweredGuard, $ParityCohort, $mem.DeclaringType)) { return $false }
    $Pattern.LoweredEvaluator = $pscDelegate
    $Pattern.LoweredReady = $true
    $Pattern.ExecutionTier = [HuntExecutionTier]::ExternalDelegate
    return $true
}

# ==============================================================================
# 4. Provenance Audit, Pattern Search, Sign Tail & Frozen Epoch Judgment
# ==============================================================================
function Assert-HuntCases {
    param([HuntCase[]]$Cases, [bool]$Synthetic)
    $blockById = [System.Collections.Generic.Dictionary[string, HuntBlock]]::new([StringComparer]::Ordinal)
    $ownerBlocks = [System.Collections.Generic.Dictionary[object, HuntBlock]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    $rootFamilies = [System.Collections.Generic.Dictionary[object, object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    foreach ($case in $Cases) {
        if ($null -eq $case.Referent -or $null -eq $case.Context -or $null -eq $case.Block -or $case.Synthetic -ne $Synthetic) {
            throw 'Missing identity/context/block or synthetic/real mismatch'
        }
        $block = $case.Block
        if ([string]::IsNullOrEmpty($block.Identity) -or $null -eq $block.Owner -or !$block.Roots.Length) {
            throw 'Sampling unit lacks audited provenance'
        }
        if ($blockById.ContainsKey($block.Identity) -and ![object]::ReferenceEquals($blockById[$block.Identity], $block)) {
            throw 'Duplicate block identity with different live instances'
        }
        $blockById[$block.Identity] = $block
        if ($ownerBlocks.ContainsKey($block.Owner) -and ![object]::ReferenceEquals($ownerBlocks[$block.Owner], $block)) {
            throw 'Same sampling owner allocated to different blocks'
        }
        $ownerBlocks[$block.Owner] = $block
        $axes = [System.Collections.Generic.HashSet[HuntAxis]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
        foreach ($reading in $case.Readings) {
            if ($null -eq $reading.Axis -or $null -eq $reading.Axis.SemanticMember -or $null -eq $reading.Observation -or $null -eq $reading.Coordinate -or ![double]::IsFinite($reading.Value) -or !$axes.Add($reading.Axis)) {
                throw 'Unresolved, nonfinite, duplicate or ungrounded reading'
            }
        }
        foreach ($root in $block.Roots) {
            if ($null -eq $root.Source -or $null -eq $root.EvidenceFamily) { throw 'Unaudited root' }
            if ($rootFamilies.ContainsKey($root.Source) -and ![object]::Equals($rootFamilies[$root.Source], $root.EvidenceFamily)) {
                throw 'Same root counted as different evidence families'
            }
            $rootFamilies[$root.Source] = $root.EvidenceFamily
        }
    }
}

function Find-HuntPattern {
    param(
        [HuntSession]$Session,
        [HuntCase[]]$Discovery,
        [HuntAxis[]]$Inputs,
        [HuntAxis[]]$Outputs,
        [double]$Tolerance,
        [switch]$Specialize,
        [HuntPattern]$Predecessor,
        [int]$MaxCandidates = 256
    )
    if (![double]::IsFinite($Tolerance) -or $Tolerance -le 0 -or $MaxCandidates -lt 1) {
        throw 'Declare a positive measurement tolerance and search budget in advance'
    }
    Assert-HuntCases $Discovery $Session.Synthetic
    $contexts = [System.Collections.Generic.List[object]]::new()
    foreach ($case in $Discovery) { if (!$contexts.Contains($case.Context)) { $contexts.Add($case.Context) } }
    if ($Specialize) { $scopes = $contexts.ToArray() } else { $scopes = , ([object]::new()) }
    $count = 0
    foreach ($out in $Outputs) {
        foreach ($in in $Inputs) {
            if ([object]::ReferenceEquals($in, $out)) { continue }
            foreach ($scope in $scopes) {
                if (++$count -gt $MaxCandidates) { throw 'Candidate budget exceeded; narrow typed nomination before acquisition' }
                $groups = [System.Collections.Generic.Dictionary[HuntBlock, System.Collections.Generic.List[HuntCase]]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
                foreach ($case in $Discovery) {
                    if ($Specialize -and ![object]::Equals($scope, $case.Context)) { continue }
                    if ($null -eq $case.Find($in) -or $null -eq $case.Find($out)) { continue }
                    if (!$groups.ContainsKey($case.Block)) { $groups.Add($case.Block, [System.Collections.Generic.List[HuntCase]]::new()) }
                    $groups[$case.Block].Add($case)
                }
                if ($groups.Count -lt 3) { continue }
                $xs = [System.Collections.Generic.List[double]]::new()
                $ys = [System.Collections.Generic.List[double]]::new()
                $used = [System.Collections.Generic.List[HuntCase]]::new()
                foreach ($rows in $groups.Values) {
                    $x = 0.0; $y = 0.0
                    foreach ($row in $rows) { $x += $row.Find($in).Value; $y += $row.Find($out).Value; $used.Add($row) }
                    $xs.Add($x / $rows.Count); $ys.Add($y / $rows.Count)
                }
                $mx = 0.0; $my = 0.0
                for ($i = 0; $i -lt $xs.Count; $i++) { $mx += $xs[$i]; $my += $ys[$i] }
                $mx /= $xs.Count; $my /= $ys.Count
                $xx = 0.0; $xy = 0.0
                for ($i = 0; $i -lt $xs.Count; $i++) { $dx = $xs[$i] - $mx; $xx += $dx * $dx; $xy += $dx * ($ys[$i] - $my) }
                if ($xx -le 1e-20) { continue }

                $p = [HuntPattern]::new()
                $p.InputAxis = $in; $p.OutputAxis = $out; $p.Scoped = $Specialize.IsPresent
                if ($Specialize) { $p.Context = $scope }
                $p.ObservedContexts = $contexts.ToArray()
                $p.Slope = $xy / $xx; $p.Offset = $my - $p.Slope * $mx; $p.Baseline = $my
                $p.Tolerance = $Tolerance; $p.Discovery = $used.ToArray(); $p.Synthetic = $Session.Synthetic; $p.Predecessor = $Predecessor
                if (![double]::IsFinite($p.Slope) -or ![double]::IsFinite($p.Offset)) { continue }
                $j = [HuntJudgment]::new(); $j.Reliance = [HuntReliance]::Proposed; $j.Reason = 'Frozen hypothesis; not yet judged'
                $p.Record($j)
                $p
            }
        }
    }
}

function Get-HuntSignTail {
    param([int]$Wins, [int]$Losses)
    $n = $Wins + $Losses; if ($n -eq 0) { return 1.0 }; if ($Wins -le $n / 2) { return 1.0 }
    $logChoose = 0.0; for ($k = 1; $k -le $Wins; $k++) { $logChoose += [Math]::Log($n - $k + 1) - [Math]::Log($k) }
    $term = [Math]::Exp($logChoose - $n * [Math]::Log(2.0)); $sum = $term
    for ($k = $Wins; $k -lt $n; $k++) { $term *= ($n - $k) / ($k + 1.0); $sum += $term }
    return [Math]::Min(1.0, [Math]::Max([double]::Epsilon, $sum))
}

function New-HuntInput {
    param([HuntCase]$Case, [HuntAxis]$Output, [HuntAxis]$InputAxis)
    $v = [HuntCase]::new(); $v.Referent = $Case.Referent; $v.Context = $Case.Context; $v.Block = $Case.Block; $v.Synthetic = $Case.Synthetic
    $list = [System.Collections.Generic.List[HuntReading]]::new()
    if (!$Case.Synthetic) {
        if (!$InputAxis -or [object]::ReferenceEquals($InputAxis,$Output) -or $Case.Referent -isnot [HuntPredictiveScalar]) {
            throw 'Real inputs must declare a disjoint, isolated scalar coordinate.'
        }
        $sourceReading=$Case.Find($InputAxis)
        if (!$sourceReading -or $sourceReading.Value -ne $Case.Referent.Value) { throw 'Scalar projection differs from the input coordinate.' }
        $projected=[HuntReading]::new()
        $projected.Axis=$InputAxis
        $projected.Observation=$Case.Referent
        $projected.Coordinate=$Case.Referent
        $projected.Value=$Case.Referent.Value
        $list.Add($projected)
    } else {
        foreach ($reading in $Case.Readings) { if (![object]::ReferenceEquals($reading.Axis, $Output)) { $list.Add($reading) } }
    }
    $v.Readings = $list.ToArray(); return $v
}

function When-HuntPattern {
    param([HuntPattern]$Pattern, [HuntCase]$InputCase, [switch]$Trial)
    if (!$Pattern.Synthetic -and ($InputCase.Referent -isnot [HuntPredictiveScalar] -or $Pattern.WhenGuards.Count)) {
        throw 'Real prediction requires a target-isolated scalar and cannot evaluate referent guards.'
    }
    if (!$Pattern.Applies($InputCase)) { return }
    if (!$Pattern.DependenciesCurrent()) { return }
    if (!$Trial -and $Pattern.Current.Reliance -ne [HuntReliance]::SyntheticAdmitted) { return }
    if ($Trial -and $Pattern.Current.Reliance -ne [HuntReliance]::Proposed) { throw 'A validation trial requires a frozen proposal' }
    if ($InputCase.Find($Pattern.OutputAxis)) { throw 'Outcome must not be supplied to recognizer' }
    $reading = $InputCase.Find($Pattern.InputAxis); if ($null -eq $reading) { return }
    $expected = if ($Pattern.Synthetic) {
        $Pattern.EvaluateFast($InputCase,$reading)
    } elseif ($Pattern.LoweredReady) {
        $Pattern.EvaluateProjected($InputCase.Referent.Value)
    } else {
        $Pattern.Evaluate($InputCase.Referent.Value)
    }
    if (![double]::IsFinite($expected)) { return }
    $prediction = [HuntPrediction]::new()
    $prediction.Pattern = $Pattern; $prediction.Input = $InputCase; $prediction.InputReading = $reading
    $prediction.Judgment = $Pattern.Current; $prediction.Expected = $expected; $prediction.At = [datetime]::UtcNow
    return $prediction
}

function Ergo-HuntOutcome {
    param([HuntPrediction]$Prediction, [HuntCase]$Observed)
    if (![object]::ReferenceEquals($Prediction.Input.Referent, $Observed.Referent) -or ![object]::ReferenceEquals($Prediction.Input.Block, $Observed.Block) -or ![object]::Equals($Prediction.Input.Context, $Observed.Context) -or $Prediction.Input.Synthetic -ne $Observed.Synthetic) {
        throw 'Outcome belongs to a different observation coordinate'
    }
    $actual = $Observed.Find($Prediction.Pattern.OutputAxis); if ($null -eq $actual) { return }
    $o = [HuntOutcome]::new()
    $o.Prediction = $Prediction; $o.Actual = $actual
    $o.Error = [Math]::Abs($actual.Value - $Prediction.Expected)
    $o.OutsideBound = $o.Error -gt $Prediction.Pattern.Tolerance
    return $o
}

class HuntEpoch {
    [HuntSession] $Session; [int] $Number; [double] $Alpha; [HuntTrial[]] $Trials = @(); [HuntCase[]] $Inputs = @(); [bool] $Closed
}

function Start-HuntJudgment {
    param([HuntSession]$Session, [HuntPattern[]]$Patterns, [HuntCase[]]$Inputs)
    if (!$Patterns.Length -or !$Inputs.Length) { throw 'A frozen family and a separate input set are required' }
    Assert-HuntCases $Inputs $Session.Synthetic
    $training = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $trainingOwners = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    $outAxes = [System.Collections.Generic.HashSet[HuntAxis]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    foreach ($p in $Patterns) {
        if ($p.Synthetic -ne $Session.Synthetic -or $p.Current.Reliance -ne [HuntReliance]::Proposed -or !$p.DependenciesCurrent()) {
            throw 'Invalid frozen candidate'
        }
        $null = $outAxes.Add($p.OutputAxis)
        foreach ($c in $p.Discovery) { $null = $training.Add($c.Block.Identity); $null = $trainingOwners.Add($c.Block.Owner) }
    }
    $newBlocks = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $refs = [System.Collections.Generic.HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    foreach ($c in $Inputs) {
        if ($training.Contains($c.Block.Identity) -or $trainingOwners.Contains($c.Block.Owner) -or $Session.Consumed.Contains($c.Block.Identity) -or $Session.ConsumedOwners.Contains($c.Block.Owner)) {
            throw 'Holdout leakage or reuse'
        }
        if (!$refs.Add($c.Referent)) { throw 'Ambiguous input coordinate' }
        foreach ($r in $c.Readings) {
            if ($outAxes.Contains($r.Axis)) { throw 'Held-out target present in frozen inputs; split candidate families by available evidence' }
        }
        $null = $newBlocks.Add($c.Block.Identity)
    }
    foreach ($id in $newBlocks) { $null = $Session.Consumed.Add($id) }
    foreach ($c in $Inputs) { $null = $Session.ConsumedOwners.Add($c.Block.Owner) }
    $epoch = [HuntEpoch]::new(); $epoch.Session = $Session; $epoch.Alpha = $Session.NextAlpha(); $epoch.Number = $Session.Epoch; $epoch.Inputs = $Inputs
    $trials = [System.Collections.Generic.List[HuntTrial]]::new()
    foreach ($p in $Patterns) {
        $trial = [HuntTrial]::new(); $trial.Pattern = $p; $preds = [System.Collections.Generic.List[HuntPrediction]]::new()
        foreach ($c in $Inputs) { $pred = When-HuntPattern $p $c -Trial; if ($null -ne $pred) { $preds.Add($pred) } }
        $trial.Predictions = $preds.ToArray(); $trials.Add($trial); $Session.Trials.Add($trial)
    }
    $epoch.Trials = $trials.ToArray(); return $epoch
}

function Complete-HuntJudgment {
    param([HuntEpoch]$Epoch, [HuntCase[]]$Holdout)
    if ($Epoch.Closed) { throw 'Frozen epoch already judged' }
    $Epoch.Closed = $true; $Session = $Epoch.Session
    Assert-HuntCases $Holdout $Session.Synthetic
    $caseByRef = [System.Collections.Generic.Dictionary[object, HuntCase]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    foreach ($c in $Holdout) { if (!$caseByRef.TryAdd($c.Referent, $c)) { throw 'Ambiguous held-out coordinate; adapter must resolve observation identity' } }
    if ($Holdout.Length -ne $Epoch.Inputs.Length) { throw 'Outcome cohort differs from frozen input cohort' }
    foreach ($inputCase in $Epoch.Inputs) {
        if (!$caseByRef.ContainsKey($inputCase.Referent)) { throw 'Frozen input missing from outcome cohort' }
        $observed = $caseByRef[$inputCase.Referent]
        if (![object]::ReferenceEquals($inputCase.Block, $observed.Block) -or ![object]::Equals($inputCase.Context, $observed.Context)) {
            throw 'Outcome provenance or context changed after freeze'
        }
    }
    $family = $Epoch.Trials.Length
    foreach ($trial in $Epoch.Trials) {
        $p = $trial.Pattern; $j = [HuntJudgment]::new(); $j.Alpha = $Epoch.Alpha; $j.Reliance = [HuntReliance]::Insufficient
        $blocks = [System.Collections.Generic.Dictionary[HuntBlock, double[]]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
        $families = [System.Collections.Generic.HashSet[object]]::new()
        $used = [System.Collections.Generic.List[HuntCase]]::new(); $outcomes = [System.Collections.Generic.List[HuntOutcome]]::new()
        $missing = 0
        foreach ($pred in $trial.Predictions) {
            if (!$pred.IsCurrent()) { throw 'Candidate dependencies changed after freeze' }
            $case = $caseByRef[$pred.Input.Referent]; $o = Ergo-HuntOutcome $pred $case
            if ($null -eq $o) { $missing++; continue }
            $outcomes.Add($o); $used.Add($case); $Session.Outcomes.Add($o)
            if ($o.OutsideBound) { $j.OutsideBound++ }
            if (!$blocks.ContainsKey($case.Block)) { $blocks.Add($case.Block, [double[]]::new(2)) }
            $s = $blocks[$case.Block]; $s[0] += [Math]::Abs($o.Actual.Value - $p.Baseline) - $o.Error; $s[1]++
            foreach ($root in $case.Block.Roots) { $null = $families.Add($root.EvidenceFamily) }
        }
        foreach ($s in $blocks.Values) {
            $mean = $s[0] / $s[1]
            if ($mean -gt 1e-10) { $j.Wins++ } elseif ($mean -lt -1e-10) { $j.Losses++ } else { $j.Ties++ }
        }
        $j.IndependentBlocks = $blocks.Count; $j.OriginFamilies = $families.Count
        $j.P = Get-HuntSignTail $j.Wins $j.Losses; $j.AdjustedP = [Math]::Min(1.0, $j.P * $family)
        $j.Evidence = $used.ToArray(); $j.MissingOutcomes = $missing
        if ($missing -eq 0 -and $j.AdjustedP -lt $Epoch.Alpha -and $j.OriginFamilies -ge 3 -and $j.OutsideBound -eq 0) {
            $j.Reliance = if ($Session.Synthetic) { [HuntReliance]::SyntheticAdmitted } else { [HuntReliance]::Nominated }
            $j.Reason = 'Frozen held-out paired-loss sign test passed and observed residuals within declared bound; independent source judgment required in real mode'
            $null = $p.TryCompileAndVerifyLowered($used.ToArray())
            foreach ($evCase in $used) { $Session.Attach($evCase.Referent).Patterns.Add($p) }
        }
        else {
            $j.Reason = 'Incomplete outcomes, insufficient evidence, residual bound failed, or family-wise threshold not met'
            $rev = [HuntReverie]::new()
            $rev.Pattern = $p
            $rev.CooldownReason = "AdjustedP=$($j.AdjustedP); OriginFamilies=$($j.OriginFamilies); OutsideBound=$($j.OutsideBound)"
            $null = $rev.WakeAxes.Add($p.InputAxis); $null = $rev.WakeAxes.Add($p.OutputAxis)
            $Session.Reveries.Add($rev)
        }
        $trial.Outcomes = $outcomes.ToArray(); $trial.Closed = $true; $p.Record($j); $Session.Patterns.Add($p); $p
    }
}

function Invoke-HuntJudgment {
    param([HuntSession]$Session, [HuntPattern[]]$Patterns, [HuntCase[]]$Holdout)
    if (!$Session.Synthetic) { throw 'Real evaluation requires Start-HuntJudgment then independently read outcomes and Complete-HuntJudgment' }
    if (!$Patterns.Length) { return }
    $inputs = [System.Collections.Generic.List[HuntCase]]::new()
    foreach ($c in $Holdout) { $v = $c; foreach ($p in $Patterns) { $v = New-HuntInput $v $p.OutputAxis }; $inputs.Add($v) }
    $epoch = Start-HuntJudgment $Session $Patterns $inputs.ToArray()
    Complete-HuntJudgment $epoch $Holdout
}

function Reconsider-HuntPattern {
    param([HuntSession]$Session, [HuntPrediction]$Prediction, [HuntCase]$Observed)
    if (!$Prediction.IsCurrent()) { throw 'Stale recognition; reconsider under current judgment before relying on it' }
    Assert-HuntCases @($Observed) $Session.Synthetic
    $o = Ergo-HuntOutcome $Prediction $Observed; if ($null -eq $o) { throw 'Missing independently observed outcome' }
    $Session.Outcomes.Add($o)
    if ($o.OutsideBound) {
        $p = $Prediction.Pattern; $p.Counterexamples.Add($Observed)
        $j = [HuntJudgment]::new(); $j.Reliance = [HuntReliance]::Demoted; $j.Evidence = @($Observed)
        $j.Reason = 'Bounded prediction failed; operational reliance suspended pending accommodation (not proof of negation or a recalculated p-value)'
        $p.Record($j)
        $rev = [HuntReverie]::new(); $rev.Pattern = $p; $rev.CooldownReason = 'Demoted on counterexample; awaiting discriminating split or new capability'
        $null = $rev.WakeAxes.Add($p.InputAxis); $null = $rev.WakeAxes.Add($p.OutputAxis)
        $Session.Reveries.Add($rev)
    }
    return $o
}

# ==============================================================================
# 5. Indexed Nomination, Composition, Retrospective Revisit & Full-Fidelity PSNL
# ==============================================================================
class HuntRecognitionIndex {
    [System.Collections.Generic.Dictionary[HuntAxis, System.Collections.Generic.Dictionary[object, System.Collections.Generic.List[HuntPattern]]]] $ByAxis = [System.Collections.Generic.Dictionary[HuntAxis, System.Collections.Generic.Dictionary[object, System.Collections.Generic.List[HuntPattern]]]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    [long] $CandidateVisits
    [void] Add([HuntPattern] $Pattern) {
        if ($Pattern.Current.Reliance -ne [HuntReliance]::SyntheticAdmitted) {
            throw 'Only verified synthetic patterns in this draft index; real admission belongs to the existing Student judge'
        }
        if (!$this.ByAxis.ContainsKey($Pattern.InputAxis)) {
            $this.ByAxis.Add($Pattern.InputAxis, [System.Collections.Generic.Dictionary[object, System.Collections.Generic.List[HuntPattern]]]::new())
        }
        $map = $this.ByAxis[$Pattern.InputAxis]
        $contexts = $Pattern.ObservedContexts
        if ($Pattern.Scoped) { $contexts = @($Pattern.Context) }
        foreach ($ctx in $contexts) {
            if (!$map.ContainsKey($ctx)) { $map.Add($ctx, [System.Collections.Generic.List[HuntPattern]]::new()) }
            if (!$map[$ctx].Contains($Pattern)) { $map[$ctx].Add($Pattern) }
        }
    }
    [HuntPattern[]] Nominate([HuntCase]$Case) {
        $found = [System.Collections.Generic.List[HuntPattern]]::new()
        foreach ($reading in $Case.Readings) {
            if (!$this.ByAxis.ContainsKey($reading.Axis)) { continue }
            $map = $this.ByAxis[$reading.Axis]; if (!$map.ContainsKey($Case.Context)) { continue }
            foreach ($pattern in $map[$Case.Context]) {
                $this.CandidateVisits++
                if ($pattern.Current.Reliance -eq [HuntReliance]::SyntheticAdmitted -and $pattern.DependenciesCurrent()) {
                    $found.Add($pattern)
                }
            }
        }
        return $found.ToArray()
    }
}

function Join-HuntPattern {
    param([HuntPattern]$First, [HuntPattern]$Second, [double]$Tolerance)
    if (![object]::ReferenceEquals($First.OutputAxis, $Second.InputAxis)) { throw 'Composition requires the same actual semantic intermediate identity' }
    if ($First.Synthetic -ne $Second.Synthetic -or !$First.DependenciesCurrent() -or !$Second.DependenciesCurrent()) { throw 'Unavailable constituent' }
    if ($First.Current.Reliance -ne [HuntReliance]::SyntheticAdmitted -or $Second.Current.Reliance -ne [HuntReliance]::SyntheticAdmitted) {
        throw 'Real composition must use admitted relations from the existing Student'
    }
    if ([object]::ReferenceEquals($First.InputAxis, $Second.OutputAxis)) { throw 'Self relation is not a novel composition' }
    if (![double]::IsFinite($Tolerance) -or $Tolerance -le 0) { throw 'Declare compound error bound before judgment' }
    $contexts = [System.Collections.Generic.List[object]]::new()
    foreach ($ctx in $First.ObservedContexts) {
        if ($First.Scoped -and ![object]::Equals($First.Context, $ctx)) { continue }
        if ($Second.Scoped -and ![object]::Equals($Second.Context, $ctx)) { continue }
        foreach ($other in $Second.ObservedContexts) { if ([object]::Equals($ctx, $other) -and !$contexts.Contains($ctx)) { $contexts.Add($ctx) } }
    }
    if (!$contexts.Count) { return }
    $p = [HuntPattern]::new(); $p.InputAxis = $First.InputAxis; $p.OutputAxis = $Second.OutputAxis
    $p.Slope = $Second.Slope * $First.Slope; $p.Offset = $Second.Slope * $First.Offset + $Second.Offset; $p.Baseline = $Second.Baseline
    $p.Tolerance = $Tolerance; $p.ObservedContexts = $contexts.ToArray(); $p.Scoped = $contexts.Count -eq 1
    if ($p.Scoped) { $p.Context = $contexts[0] }; $p.Synthetic = $First.Synthetic
    $p.Constituents = @($First, $Second); $p.ConstituentJudgments = @($First.Current, $Second.Current)
    $First.RegisterDependent($p); $Second.RegisterDependent($p)
    $disc = [System.Collections.Generic.List[HuntCase]]::new()
    foreach ($parent in @($First, $Second)) {
        foreach ($c in $parent.Discovery) { $disc.Add($c) }
        foreach ($hj in $parent.History) { foreach ($c in $hj.Evidence) { $disc.Add($c) } }
    }
    $p.Discovery = $disc.ToArray()
    $j = [HuntJudgment]::new(); $j.Reliance = [HuntReliance]::Proposed; $j.Reason = 'Composition nominated from acquired relations; fresh final-output judgment required'
    $p.Record($j)
    return $p
}

function Invoke-HuntCapabilityRevisit {
    param(
        [HuntSession]$Session, [string]$CapabilityName, [HuntCase[]]$DiscoveryCohort, [HuntCase[]]$HoldoutCohort,
        [HuntAxis]$UnlockedInputAxis, [HuntAxis]$TargetOutputAxis, [double]$Tolerance
    )
    $null = $Session.Capabilities.Add($CapabilityName)
    foreach ($rev in $Session.Reveries) {
        if ($rev.Status -eq 'DormantCooldown' -and ($rev.WakeCapabilities.Contains($CapabilityName) -or $rev.WakeAxes.Contains($UnlockedInputAxis))) {
            $rev.Status = 'Active'
            $rev.CooldownReason = "Woken by capability '$CapabilityName'"
        }
    }
    $proposals = @(Find-HuntPattern $Session $DiscoveryCohort @($UnlockedInputAxis) @($TargetOutputAxis) $Tolerance)
    if (!$proposals.Length) { return @() }
    return @(Invoke-HuntJudgment $Session $proposals $HoldoutCohort)
}

function Format-HuntPsnlValue {
    param(
        [object]$Val,
        [System.Collections.Generic.Dictionary[object, string]]$RefTable,
        [System.Collections.Generic.List[string]]$SourceRefDecls
    )
    if ($null -eq $Val) { return '$null' }
    if ($Val -is [bool]) { return $(if ($Val) { '$true' } else { '$false' }) }
    if ($Val -is [int] -or $Val -is [long]) { return "$Val" }
    if ($Val -is [double]) {
        if ([double]::IsNaN($Val)) { return '[double]::NaN' }
        if ([double]::IsPositiveInfinity($Val)) { return '[double]::PositiveInfinity' }
        if ([double]::IsNegativeInfinity($Val)) { return '[double]::NegativeInfinity' }
        return $Val.ToString('R')
    }
    if ($Val -is [string]) { return "'$($Val -replace "'","''")'" }
    if ($Val -is [guid]) { return "[guid]'$Val'" }
    if ($Val -is [datetime]) { return "[datetime]::FromBinary($($Val.ToBinary()))" }
    if ($Val.GetType().IsEnum) { return "[$($Val.GetType().FullName)]::$Val" }
    if ($Val -is [type]) { return "[$($Val.FullName)]" }
    if ($Val -is [System.Reflection.MemberInfo]) {
        return "([$($Val.DeclaringType.FullName)].GetMember('$($Val.Name)')[0])"
    }
    if ($null -ne $RefTable -and $RefTable.ContainsKey($Val)) { return $RefTable[$Val] }

    # Deduplicate external source/referent objects into typed HuntSourceCleanReference instances
    $idx = $SourceRefDecls.Count
    $varRef = "`$sourceRefs[$idx]"
    $RefTable[$Val] = $varRef
    $hash = [long][System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Val)
    $tname = $Val.GetType().FullName
    $SourceRefDecls.Add("`$sourceRefs.Add([HuntSourceCleanReference]::new('$($tname -replace "'","''")', ${hash}L, '$($Val.GetType().Name)'))")
    return $varRef
}

function Export-HuntPsnlScript {
    <#
    .SYNOPSIS
        Full-fidelity PSNL export preserving Axis/Pattern identities, deduplicated
        HuntSourceCleanReference external handles (maintaining ReferenceEquals across
        Referent/Owner/Origin/Observation/Coordinate), all HuntOrigin, HuntBlock, HuntCase,
        HuntReading, Discovery, Counterexamples, complete Judgment History + Trigger + Evidence,
        Constituents, Predecessor, Dependents, and Reveries.
        LoweredReady stays $false until a live ParityCohort validates equivalence on reload.
    #>
    param([Parameter(Mandatory)][HuntSession]$Session)
    $refMap = [System.Collections.Generic.Dictionary[object, string]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    $srcRefDecls = [System.Collections.Generic.List[string]]::new()
    $bodySb = [System.Text.StringBuilder]::new()

    # 1. Axes
    $seenAxes = [System.Collections.Generic.HashSet[guid]]::new()
    foreach ($p in $Session.Patterns) {
        foreach ($ax in @($p.InputAxis, $p.OutputAxis)) {
            if ($seenAxes.Add($ax.Identity)) {
                $semExpr = Format-HuntPsnlValue $ax.SemanticMember $refMap $srcRefDecls
                [void]$bodySb.AppendLine("`$ax = [HuntAxis]::new(); `$ax.Identity = [guid]'$($ax.Identity)'; `$ax.Name = '$($ax.Name -replace "'","''")'; `$ax.Units = '$($ax.Units -replace "'","''")'; `$ax.SemanticMember = $semExpr; `$axesById[`$ax.Identity] = Resolve-HuntAxis `$ax `$LiveAxes")
            }
        }
    }

    # 2. Collect unique Cases & Judgments iteratively (zero nested scope mutations)
    $allCases = [System.Collections.Generic.List[HuntCase]]::new()
    $allJudgments = [System.Collections.Generic.List[HuntJudgment]]::new()
    $jQueue = [System.Collections.Generic.Queue[HuntJudgment]]::new()
    foreach ($p in $Session.Patterns) {
        foreach ($c in $p.Discovery) {
            if ($null -ne $c -and !$refMap.ContainsKey($c)) { $refMap[$c] = "`$cases[$($allCases.Count)]"; $allCases.Add($c) }
        }
        foreach ($c in $p.Counterexamples) {
            if ($null -ne $c -and !$refMap.ContainsKey($c)) { $refMap[$c] = "`$cases[$($allCases.Count)]"; $allCases.Add($c) }
        }
        foreach ($hj in $p.History) { if ($null -ne $hj) { $jQueue.Enqueue($hj) } }
        foreach ($cj in $p.ConstituentJudgments) { if ($null -ne $cj) { $jQueue.Enqueue($cj) } }
    }
    while ($jQueue.Count -gt 0) {
        $j = $jQueue.Dequeue()
        if ($refMap.ContainsKey($j)) { continue }
        $refMap[$j] = "`$judgments[$($allJudgments.Count)]"; $allJudgments.Add($j)
        foreach ($ev in $j.Evidence) {
            if ($null -ne $ev -and !$refMap.ContainsKey($ev)) { $refMap[$ev] = "`$cases[$($allCases.Count)]"; $allCases.Add($ev) }
        }
        if ($null -ne $j.Trigger) { $jQueue.Enqueue($j.Trigger) }
    }

    # 3. Emit Origins & Blocks
    $originCount = 0; $blockCount = 0
    foreach ($c in $allCases) {
        foreach ($rt in $c.Block.Roots) {
            if (!$refMap.ContainsKey($rt)) {
                $refMap[$rt] = "`$origins[$originCount]"; $originCount++
                $srcExpr = Format-HuntPsnlValue $rt.Source $refMap $srcRefDecls
                $famExpr = Format-HuntPsnlValue $rt.EvidenceFamily $refMap $srcRefDecls
                [void]$bodySb.AppendLine("`$or = [HuntOrigin]::new(); `$or.Source = $srcExpr; `$or.EvidenceFamily = $famExpr; `$origins.Add(`$or)")
            }
        }
        if (!$refMap.ContainsKey($c.Block)) {
            $refMap[$c.Block] = "`$blocks[$blockCount]"; $blockCount++
            $ownExpr = Format-HuntPsnlValue $c.Block.Owner $refMap $srcRefDecls
            $rtRefs = ($c.Block.Roots | ForEach-Object { $refMap[$_] }) -join ', '
            [void]$bodySb.AppendLine("`$bl = [HuntBlock]::new(); `$bl.Identity = '$($c.Block.Identity -replace "'","''")'; `$bl.Owner = $ownExpr; `$bl.Roots = [HuntOrigin[]]@($rtRefs); `$blocks.Add(`$bl)")
        }
    }

    # 4. Emit Cases & Readings cleanly via $rdList
    foreach ($c in $allCases) {
        $refExpr = Format-HuntPsnlValue $c.Referent $refMap $srcRefDecls
        $ctxExpr = Format-HuntPsnlValue $c.Context $refMap $srcRefDecls
        $blkRef = $refMap[$c.Block]
        $synLit = if ($c.Synthetic) { '$true' } else { '$false' }
        [void]$bodySb.AppendLine("`$cs = [HuntCase]::new(); `$cs.Referent = $refExpr; `$cs.Context = $ctxExpr; `$cs.Block = $blkRef; `$cs.Synthetic = $synLit; `$rdList = [System.Collections.Generic.List[HuntReading]]::new()")
        foreach ($r in $c.Readings) {
            $obsExpr = Format-HuntPsnlValue $r.Observation $refMap $srcRefDecls
            $crdExpr = Format-HuntPsnlValue $r.Coordinate $refMap $srcRefDecls
            [void]$bodySb.AppendLine("`$rd = [HuntReading]::new(); `$rd.Axis = `$axesById[[guid]'$($r.Axis.Identity)']; `$rd.Observation = $obsExpr; `$rd.Coordinate = $crdExpr; `$rd.Value = $($r.Value.ToString('R')); `$rdList.Add(`$rd)")
        }
        [void]$bodySb.AppendLine("`$cs.Readings = `$rdList.ToArray(); `$cases.Add(`$cs)")
    }

    # 5. Emit Judgments & Trigger links
    foreach ($j in $allJudgments) {
        $evRefs = ($j.Evidence | ForEach-Object { $refMap[$_] }) -join ', '
        $atExpr = Format-HuntPsnlValue $j.At $refMap $srcRefDecls
        $pLit = Format-HuntPsnlValue $j.P $refMap $srcRefDecls
        $apLit = Format-HuntPsnlValue $j.AdjustedP $refMap $srcRefDecls
        [void]$bodySb.AppendLine("`$jd = [HuntJudgment]::new(); `$jd.Version = $($j.Version); `$jd.At = $atExpr; `$jd.Reliance = [HuntReliance]::$($j.Reliance); `$jd.P = $pLit; `$jd.AdjustedP = $apLit; `$jd.IndependentBlocks = $($j.IndependentBlocks); `$jd.Wins = $($j.Wins); `$jd.Losses = $($j.Losses); `$jd.Ties = $($j.Ties); `$jd.OutsideBound = $($j.OutsideBound); `$jd.MissingOutcomes = $($j.MissingOutcomes); `$jd.OriginFamilies = $($j.OriginFamilies); `$jd.Alpha = $($j.Alpha.ToString('R')); `$jd.Evidence = [HuntCase[]]@($evRefs); `$jd.Reason = '$($j.Reason -replace "'","''")'; `$judgments.Add(`$jd)")
    }
    foreach ($j in $allJudgments) {
        if ($null -ne $j.Trigger) {
            [void]$bodySb.AppendLine("$($refMap[$j]).Trigger = $($refMap[$j.Trigger])")
        }
    }

    # 6. Emit Patterns & structural links
    foreach ($p in $Session.Patterns) {
        $ctxExpr = Format-HuntPsnlValue $p.Context $refMap $srcRefDecls
        $obsList = ($p.ObservedContexts | ForEach-Object { Format-HuntPsnlValue $_ $refMap $srcRefDecls }) -join ', '
        $discRefs = ($p.Discovery | ForEach-Object { $refMap[$_] }) -join ', '
        $cxRefs = ($p.Counterexamples | ForEach-Object { $refMap[$_] }) -join ', '
        $cjRefs = ($p.ConstituentJudgments | ForEach-Object { $refMap[$_] }) -join ', '
        $synLit = if ($p.Synthetic) { '$true' } else { '$false' }
        $scpLit = if ($p.Scoped) { '$true' } else { '$false' }
        $depValLit = if ($p.DependenciesCurrent()) { '$true' } else { '$false' }

        [void]$bodySb.AppendLine("`$p = [HuntPattern]::new(); `$p.Identity = [guid]'$($p.Identity)'; `$p.InputAxis = `$axesById[[guid]'$($p.InputAxis.Identity)']; `$p.OutputAxis = `$axesById[[guid]'$($p.OutputAxis.Identity)']; `$p.Scoped = $scpLit; `$p.Context = $ctxExpr; `$p.ObservedContexts = @($obsList); `$p.Slope = $($p.Slope.ToString('R')); `$p.Offset = $($p.Offset.ToString('R')); `$p.Baseline = $($p.Baseline.ToString('R')); `$p.Tolerance = $($p.Tolerance.ToString('R')); `$p.Synthetic = $synLit; `$p.ForceDependenciesValid($depValLit)")
        [void]$bodySb.AppendLine("`$p.Discovery = [HuntCase[]]@($discRefs); `$p.ConstituentJudgments = [HuntJudgment[]]@($cjRefs)")
        if ($p.Counterexamples.Count -gt 0) { [void]$bodySb.AppendLine("foreach (`$cx in @($cxRefs)) { `$p.Counterexamples.Add(`$cx) }") }
        foreach ($hj in $p.History) {
            [void]$bodySb.AppendLine("`$p.History.Add($($refMap[$hj])); `$p.Current = $($refMap[$hj])")
        }
        [void]$bodySb.AppendLine("`$patternsById[[guid]'$($p.Identity)'] = `$p; `$restored.Add(`$p)")
    }
    foreach ($p in $Session.Patterns) {
        if ($null -ne $p.Predecessor) { [void]$bodySb.AppendLine("`$patternsById[[guid]'$($p.Identity)'].Predecessor = `$patternsById[[guid]'$($p.Predecessor.Identity)']") }
        if ($p.Constituents.Count -gt 0) {
            $cRefs = ($p.Constituents | ForEach-Object { "`$patternsById[[guid]'$($_.Identity)']" }) -join ', '
            [void]$bodySb.AppendLine("`$patternsById[[guid]'$($p.Identity)'].Constituents = [HuntPattern[]]@($cRefs)")
        }
        foreach ($dep in $p.Dependents) { [void]$bodySb.AppendLine("`$patternsById[[guid]'$($p.Identity)'].RegisterDependent(`$patternsById[[guid]'$($dep.Identity)'])") }
    }

    # 7. Emit Reveries
    foreach ($rev in $Session.Reveries) {
        $wkAx = ($rev.WakeAxes | ForEach-Object { "`$axesById[[guid]'$($_.Identity)']" }) -join ', '
        $wkCp = ($rev.WakeCapabilities | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ', '
        [void]$bodySb.AppendLine("`$rv = [HuntReverie]::new(); `$rv.Identity = [guid]'$($rev.Identity)'; `$rv.Pattern = `$patternsById[[guid]'$($rev.Pattern.Identity)']; `$rv.Status = '$($rev.Status)'; `$rv.CooldownReason = '$($rev.CooldownReason -replace "'","''")'; `$rv.Heat = $($rev.Heat.ToString('R')); foreach (`$wa in @($wkAx)) { `$null = `$rv.WakeAxes.Add(`$wa) }; foreach (`$wc in @($wkCp)) { `$null = `$rv.WakeCapabilities.Add(`$wc) }; `$reveries.Add(`$rv)")
    }

    # Assemble header + sourceRefs + body
    $outSb = [System.Text.StringBuilder]::new()
    [void]$outSb.AppendLine('# Pure PSNL Competence + Evidentiary Graph Checkpoint (SMA/CoreCLR, Zero JSON/CLIXML)')
    [void]$outSb.AppendLine('param([System.Collections.Generic.Dictionary[guid,HuntAxis]] $LiveAxes)')
    [void]$outSb.AppendLine("`$sourceRefs = [System.Collections.Generic.List[HuntSourceCleanReference]]::new()")
    foreach ($decl in $srcRefDecls) { [void]$outSb.AppendLine($decl) }
    [void]$outSb.AppendLine("`$axesById = [System.Collections.Generic.Dictionary[guid, HuntAxis]]::new()")
    [void]$outSb.AppendLine("`$origins = [System.Collections.Generic.List[HuntOrigin]]::new()")
    [void]$outSb.AppendLine("`$blocks = [System.Collections.Generic.List[HuntBlock]]::new()")
    [void]$outSb.AppendLine("`$cases = [System.Collections.Generic.List[HuntCase]]::new()")
    [void]$outSb.AppendLine("`$judgments = [System.Collections.Generic.List[HuntJudgment]]::new()")
    [void]$outSb.AppendLine("`$patternsById = [System.Collections.Generic.Dictionary[guid, HuntPattern]]::new()")
    [void]$outSb.AppendLine("`$reveries = [System.Collections.Generic.List[HuntReverie]]::new()")
    [void]$outSb.AppendLine("`$restored = [System.Collections.Generic.List[HuntPattern]]::new()")
    [void]$outSb.Append($bodySb.ToString())
    [void]$outSb.AppendLine('return @($restored.ToArray(), $reveries.ToArray(), $cases.ToArray(), $judgments.ToArray())')
    return $outSb.ToString()
}

function Resolve-HuntAxis([HuntAxis]$Descriptor, [Collections.Generic.Dictionary[guid,HuntAxis]]$LiveAxes) {
    $canonical = $null
    if ($null -eq $LiveAxes -or !$LiveAxes.TryGetValue($Descriptor.Identity,[ref]$canonical)) { return $Descriptor }
    if ($canonical.Identity -ne $Descriptor.Identity -or $canonical.Units -cne $Descriptor.Units -or
        ![object]::Equals($canonical.SemanticMember,$Descriptor.SemanticMember)) {
        throw 'Checkpoint axis conflicts with the live semantic member or measurement contract.'
    }
    $canonical
}

function Invoke-HuntCapturedClock {
    param([object[]]$Comparisons)
    $axes = @{}
    foreach ($name in 'generator','spectral','waveform') {
        $axis=[HuntAxis]::new()
        $axis.Name=$name
        $axis.Units=if ($name -ceq 'waveform') {'samples'} else {'frames'}
        $axes[$name]=$axis
    }
    $cases=@(foreach ($comparison in $Comparisons) {
        $run=$comparison.Teacher.StockExecution
        if (!$run) { continue }
        $generator=$run.GeneratorInput
        $spectral=@($run.Activations | Where-Object Stage -CEQ 'decoder.module.generator.conv_post')[0]
        $wave=$run.Waveform
        if (!$generator -or !$spectral -or !$wave) { continue }
        $case=[HuntCase]::new()
        $case.Referent=[HuntPredictiveScalar]::new($generator.Extent)
        $case.Context='Captured stock generator input'
        $case.Block=[HuntBlock]::new()
        $case.Block.Owner=$run
        $case.Block.Identity=$run.Teacher.Directory
        $origin=[HuntOrigin]::new()
        $origin.Source=$run.Teacher.Document.Source
        $origin.EvidenceFamily='Stock Kokoro host captures'
        $case.Block.Roots=@($origin)
        $case.Readings=@(foreach ($pair in @(@('generator',$generator),@('spectral',$spectral),@('waveform',$wave))) {
            $observation=$pair[1]
            $axis=$axes[$pair[0]]
            $axis.SemanticMember=$observation.GetType().GetProperty('Extent')
            $reading=[HuntReading]::new()
            $reading.Axis=$axis
            $reading.Observation=$observation
            $reading.Coordinate=$run
            $reading.Value=$observation.Extent
            $reading
        })
        $case
    })
    $training=@($cases | Where-Object { $_.Block.Owner.Teacher.Document.Source.EvidenceGroup -ceq 'Gutenberg/30036' })
    $holdout=@($cases | Where-Object { $_.Block.Owner.Teacher.Document.Source.EvidenceGroup -ceq 'Gutenberg/11' })
    if ($training.Count -lt 3 -or !$holdout.Count) { throw 'Clock acquisition requires both retained source cohorts.' }
    $session=[HuntSession]::new()
    $spectrum=Find-HuntPattern $session $training @($axes.generator) @($axes.spectral) 1e-7
    $waveform=Find-HuntPattern $session $training @($axes.spectral) @($axes.waveform) 1e-7
    # A Hunt case uses the live referent of the requested input axis for expression-tree parity.
    $spectralCases=@(foreach ($case in $cases) {
        $view=[HuntCase]::new()
        $view.Context=$case.Context
        $view.Block=$case.Block
        $view.Readings=$case.Readings
        $view.Referent=[HuntPredictiveScalar]::new([int]$case.Find($axes.spectral).Value)
        $view
    })
    $spectralHoldout=@($spectralCases | Where-Object { $_.Block.Owner.Teacher.Document.Source.EvidenceGroup -ceq 'Gutenberg/11' })
    $limits=[Collections.Generic.List[HuntJudgment]]::new()
    foreach ($test in @(@($spectrum,$holdout),@($waveform,$spectralHoldout))) {
        $pattern=$test[0]
        $checks=$test[1]
        $epoch=Start-HuntJudgment ([HuntSession]::new()) @($pattern) @(foreach ($case in $checks) { New-HuntInput $case $pattern.OutputAxis $pattern.InputAxis })
        $judged=Complete-HuntJudgment $epoch $checks
        $limits.Add($judged.Current)
        if ($judged.Current.Evidence.Count -ne $checks.Count -or $judged.Current.OutsideBound -or
            !$pattern.TryCompileAndVerifyLowered($checks)) { throw 'Held-out stock geometry or lowering parity failed.' }
        $observed=[HuntJudgment]::new()
        $observed.Reliance=[HuntReliance]::ObservedScope
        $observed.Evidence=$checks
        $observed.Reason='Finite replay agreement on separate passages of the same model lineage.'
        $pattern.Record($observed)
    }
    $direct=[HuntPattern]::new()
    $direct.InputAxis=$spectrum.InputAxis
    $direct.OutputAxis=$waveform.OutputAxis
    if (![object]::ReferenceEquals($spectrum.OutputAxis,$waveform.InputAxis)) { throw 'Clock composition lost its shared semantic axis.' }
    $direct.Slope=$waveform.Slope*$spectrum.Slope
    $direct.Offset=$waveform.Slope*$spectrum.Offset+$waveform.Offset
    $direct.Constituents=@($spectrum,$waveform)
    $direct.ConstituentJudgments=@($spectrum.Current,$waveform.Current)
    $spectrum.RegisterDependent($direct)
    $waveform.RegisterDependent($direct)
    if (!$direct.TryCompileAndVerifyLowered($holdout)) { throw 'Composed lowering failed.' }
    $saved=0L
    foreach ($case in $holdout) {
        $actual=$case.Find($axes.waveform).Observation.Read()
        if ([long][Math]::Round($direct.LoweredEvaluator.Invoke($case.Referent)) -ne $actual.Length) {
            throw 'Composition failed independent waveform buffer verification.'
        }
        $saved+=[Buffer]::ByteLength($actual)
    }
    $observed=[HuntJudgment]::new()
    $observed.Reliance=[HuntReliance]::ObservedScope
    $observed.Evidence=$holdout
    $observed.Reason='Composed extent matched the independently read waveform buffers in the observed stock scope.'
    $direct.Record($observed)
    @{ Pattern=$direct; Checks=$holdout; Limits=$limits.ToArray(); AvoidedWaveformBytes=$saved }
}

class HuntMorphologicalReading {
    [object] $Sentence
    [int] $WordIndex
    [string] $Spelling
    [object[]] $Parses

    [bool] CompetingRules() {
        if ($this.Parses.Length -lt 2) { return $false }
        $first=$this.Parses[0].Rules[0]
        foreach ($parse in $this.Parses) { if ($parse.Rules[0] -cne $first) { return $true } }
        return $false
    }
}

class HuntPronunciationBearing {
    [object] $Sentence
    [int] $WordIndex
    [int] $ReadingIndex
    [string] $Spelling
    [object[]] $HumanCandidates
    [object[]] $TeacherContexts
    [object] $Dictionary
    [string[][]] $DictionaryAlternatives

    [int[]] GrammaticalRoles() { return $this.Sentence.Roles[$this.ReadingIndex] }
    [string] ChosenReading() { return $this.Sentence.Readings[$this.ReadingIndex] }
    [string[]] Alternatives() { return $this.Sentence.Alternatives[$this.ReadingIndex] }
}

class HuntHumanWordDuration {
    [object] $Anchor
    [object] $Recording
    [int] $WordIndex
    [long] $RecognizerDurationTicks
    [int] $FirstRmsFrame
    [int] $RmsFrameCount
    [double] $MeanRms
}

class HuntSyllableStressCoordinate {
    [object] $Occurrence
    [object] $Recording
    [long[]] $SyllableSampleSpans
    [double[]] $StressEvidence
}

class HuntUnresolvedStress : HuntReverie {
    [object] $Referent
    [type] $RequiredCoordinate = [HuntSyllableStressCoordinate]
    [HuntHumanWordDuration[]] $AvailableWordDurations
}

function Get-HuntHumanWordDurations([object[]]$Anchors) {
    $byUtterance=[Collections.Generic.Dictionary[object,Collections.Generic.List[object]]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    foreach ($anchor in $Anchors) {
        if (!$byUtterance.ContainsKey($anchor.Utterance)) { $byUtterance.Add($anchor.Utterance,[Collections.Generic.List[object]]::new()) }
        $byUtterance[$anchor.Utterance].Add($anchor)
    }
    foreach ($words in $byUtterance.Values) {
        if ($words.Count -ne 1 -or $words[0].CandidateTokens.Count -ne 1) { continue }
        $anchor=$words[0]
        $u=$anchor.Utterance
        $wave=$u.Chapter.Wave.Prosody
        if (!$wave -or $u.DecodedStartTicks -lt 0 -or $u.DecodedDurationTicks -le 0) { continue }
        $framesPerTick=$wave.Rate/([double]$wave.Hop*[TimeSpan]::TicksPerSecond)
        $first=[int][Math]::Ceiling($u.DecodedStartTicks*$framesPerTick)
        $end=[int][Math]::Min($wave.Rms.Length,[Math]::Floor(($u.DecodedStartTicks+$u.DecodedDurationTicks)*$framesPerTick))
        if ($end -le $first) { continue }
        $sum=0.0
        for ($frame=$first;$frame -lt $end;$frame++) { $sum+=$wave.Rms[$frame] }
        $bearing=[HuntHumanWordDuration]::new()
        $bearing.Anchor=$anchor
        $bearing.Recording=$wave
        $bearing.WordIndex=$anchor.CandidateTokens[0]
        $bearing.RecognizerDurationTicks=$u.DecodedDurationTicks
        $bearing.FirstRmsFrame=$first
        $bearing.RmsFrameCount=$end-$first
        $bearing.MeanRms=$sum/$bearing.RmsFrameCount
        $bearing
    }
}

function Get-HuntUnresolvedStress([HuntPronunciationBearing[]]$Pronunciations,[HuntHumanWordDuration[]]$Durations) {
    foreach ($pronunciation in $Pronunciations) {
        $question=[HuntUnresolvedStress]::new()
        $question.Referent=$pronunciation
        $question.AvailableWordDurations=@($Durations | Where-Object {
            $_.WordIndex -eq $pronunciation.WordIndex -and
            [object]::ReferenceEquals($_.Anchor.Utterance.Chapter.Document,$pronunciation.Sentence.Document)
        })
        $question
    }
}

function Get-HuntPronunciationBearings($Document,[object[]]$Comparisons,[object[]]$HumanAnchors,
    [Collections.Generic.HashSet[string]]$Spellings,$Dictionary,$LexicalAlternatives) {
    $original=[IO.File]::ReadAllText($Document.Source.Path)
    $own=@($Comparisons | Where-Object {[object]::ReferenceEquals($_.Teacher.Document,$Document)})
    $human=@($HumanAnchors | Where-Object {
        [object]::ReferenceEquals($_.Utterance.Chapter.Document,$Document) -and $Spellings.Contains($_.RecognizedWord)
    })
    foreach ($sentence in $Document.Interpretations) {
        for ($r=0;$r -lt $sentence.Readings.Length;$r++) {
            $word=$sentence.OccurrenceRanges[2*$r]
            if ($word -lt 0 -or $word -ne $sentence.OccurrenceRanges[2*$r+1] -or $Document.Tokens[4*$word] -ne 1) { continue }
            $start=$Document.OriginalSpans[2*$word]
            if ($start -lt 0) { continue }
            $spelling=$original.Substring($start,$Document.OriginalSpans[2*$word+1])
            if (!$Spellings.Contains($spelling)) { continue }
            $bearing=[HuntPronunciationBearing]::new()
            $bearing.Sentence=$sentence
            $bearing.WordIndex=$word
            $bearing.ReadingIndex=$r
            $bearing.Spelling=$spelling
            $bearing.TeacherContexts=@($own | Where-Object {$word -in $_.Teacher.WordOccurrenceIndices})
            $bearing.HumanCandidates=@($human | Where-Object {$word -in $_.CandidateTokens})
            $bearing.Dictionary=$Dictionary
            $bearing.DictionaryAlternatives=$LexicalAlternatives[$spelling]
            $bearing
        }
    }
}

function Get-HuntMorphologicalReadings($Document) {
    $source=[IO.File]::ReadAllText($Document.Source.Path)
    foreach ($sentence in $Document.Interpretations) {
        $byWord=[Collections.Generic.Dictionary[int,Collections.Generic.List[object]]]::new()
        foreach ($parse in $sentence.Morphology) {
            if (!$parse.Rules.Length) { continue }
            $first=$sentence.OccurrenceRanges[2*$parse.Occurrence]
            $last=$sentence.OccurrenceRanges[2*$parse.Occurrence+1]
            if ($first -lt 0 -or $first -ne $last -or $Document.Tokens[4*$first] -ne 1) { continue }
            if (!$byWord.ContainsKey($first)) { $byWord.Add($first,[Collections.Generic.List[object]]::new()) }
            $byWord[$first].Add($parse)
        }
        foreach ($word in $byWord.Keys) {
            $start=$Document.OriginalSpans[2*$word]
            if ($start -lt 0) { continue }
            $reading=[HuntMorphologicalReading]::new()
            $reading.Sentence=$sentence
            $reading.WordIndex=$word
            $reading.Spelling=$source.Substring($start,$Document.OriginalSpans[2*$word+1])
            $reading.Parses=$byWord[$word].ToArray()
            $reading
        }
    }
}

class HuntMorphologyInvestigation {
    [Collections.Generic.Dictionary[string,Collections.Generic.List[HuntMorphologicalReading]]] $Nominations
    [HuntMorphologicalReading[]] $Hits
    [HuntMorphologicalReading[]] $Contradictions
    [HuntMorphologicalReading[]] $Dormant
    [HuntPronunciationBearing[]] $PronunciationBearings
    [HuntHumanWordDuration[]] $HumanWordDurations
    [HuntUnresolvedStress[]] $UnresolvedStress
    [int] $Examined
    [Collections.Generic.HashSet[string]] $WithheldSpellings = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    [HuntMorphologicalReading[]] Nominate([string]$Spelling) {
        $examples=$null
        if (!$Spelling -or $this.WithheldSpellings.Contains($Spelling) -or !$this.Nominations.TryGetValue($Spelling,[ref]$examples)) {
            return @()
        }
        return $examples.ToArray()
    }
}

function Invoke-HuntMorphologicalFocus($DiscoveryDocument,$HeldOutDocument) {
    $nominations=[Collections.Generic.Dictionary[string,Collections.Generic.List[HuntMorphologicalReading]]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($reading in Get-HuntMorphologicalReadings $DiscoveryDocument) {
        if (!$reading.CompetingRules()) { continue }
        if (!$nominations.ContainsKey($reading.Spelling)) { $nominations.Add($reading.Spelling,[Collections.Generic.List[HuntMorphologicalReading]]::new()) }
        $nominations[$reading.Spelling].Add($reading)
    }
    $hits=[Collections.Generic.List[HuntMorphologicalReading]]::new()
    $contradictions=[Collections.Generic.List[HuntMorphologicalReading]]::new()
    $dormant=[Collections.Generic.List[HuntMorphologicalReading]]::new()
    $examined=0
    foreach ($reading in Get-HuntMorphologicalReadings $HeldOutDocument) {
        $examined++
        $selected=$nominations.ContainsKey($reading.Spelling)
        $competing=$reading.CompetingRules()
        if ($selected -and $competing) { $hits.Add($reading) }
        elseif ($selected) { $contradictions.Add($reading) }
        elseif ($competing) { $dormant.Add($reading) }
    }
    $result=[HuntMorphologyInvestigation]::new()
    $result.Nominations=$nominations
    $result.Hits=$hits.ToArray()
    $result.Contradictions=$contradictions.ToArray()
    foreach ($counterexample in $result.Contradictions) { $null=$result.WithheldSpellings.Add($counterexample.Spelling) }
    $result.Dormant=$dormant.ToArray()
    $result.Examined=$examined
    $result
}

# ==============================================================================
# 6. Source-Grounded Bank Adapters (Preserved from d823b7b Contract)
# ==============================================================================
function Open-HuntSpeechView {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$BankPath, [Parameter(Mandatory)][string]$SourceIdentity)
    $entry = Join-Path $Repository 'student/Open-StudentSpeechInvestigation.ps1'
    if (![IO.File]::Exists($entry)) { throw 'Existing speech investigation entry point is not available' }
    $view = & $entry -BankPath $BankPath -SourceIdentity $SourceIdentity
    if ($null -eq $view -or $null -eq $view.PSObject.Properties['Comparisons']) { throw 'Actual typed investigation return contract differs; inspect the checked-out reader' }
    foreach ($comparison in $view.Comparisons) {
        $teacher = $comparison.Teacher
        if ($null -eq $teacher -or $null -eq $teacher.Document) { throw 'Unresolved teacher source' }
        foreach ($sentence in $teacher.Sentences) { if (![object]::ReferenceEquals($teacher.Document, $sentence.Document)) { throw 'Shared document identity split' } }
        if ($comparison.HumanContext -and ![object]::ReferenceEquals($teacher.Document, $comparison.HumanContext.Document)) { throw 'Human/teacher document identity split' }
    }
    return , $view
}
class HuntInterventionMeasurement {
    [object] $Intervention; [object] $Baseline; [object] $Outcome
    [long] $Samples; [long] $ChangedSamples; [double] $PeakDifference; [double] $MeanSquaredDifference
}
function Measure-HuntResidualIntervention {
    param([Parameter(Mandatory)][object]$Intervention)
    $a = $Intervention.Baseline.Waveform.Read(); $b = $Intervention.Outcome.Waveform.Read()
    if ($a -isnot [Array] -or $b -isnot [Array] -or !$a.Length -or $a.Length -ne $b.Length) { throw 'Unaligned intervention waveform extent' }
    $m = [HuntInterventionMeasurement]::new(); $m.Intervention = $Intervention; $m.Baseline = $Intervention.Baseline; $m.Outcome = $Intervention.Outcome; $m.Samples = $a.Length
    $sum = 0.0; for ($i = 0; $i -lt $a.Length; $i++) {
        $d = [double]$a[$i] - [double]$b[$i]; if (![double]::IsFinite($d)) { throw 'Nonfinite waveform' }
        if ($d -ne 0) { $m.ChangedSamples++ }; $m.PeakDifference = [Math]::Max($m.PeakDifference, [Math]::Abs($d)); $sum += $d * $d
    }
    $m.MeanSquaredDifference = $sum / $a.Length; return $m
}
class HuntStockTokenInterval {
    [object] $Teacher; [int] $TokenIndex; [long] $StartTick; [long] $EndTick; [long] $StartSample; [long] $EndSample
}
function Get-HuntStockTokenInterval {
    param([Parameter(Mandatory)][object]$Teacher)
    $ticks = $Teacher.StockTokenTickStarts
    if ($null -eq $ticks -or $ticks.Length -lt 2 -or $ticks[0] -ne 0 -or 300L * $ticks[-1] -ne $Teacher.KokoroSamples) { throw 'Stock clock alignment not established' }
    for ($i = 0; $i -lt $ticks.Length - 1; $i++) {
        if ($ticks[$i] -lt 0 -or $ticks[$i + 1] -lt $ticks[$i]) { throw 'Nonmonotone stock token timeline' }
        $r = [HuntStockTokenInterval]::new(); $r.Teacher = $Teacher; $r.TokenIndex = $i; $r.StartTick = $ticks[$i]; $r.EndTick = $ticks[$i + 1]; $r.StartSample = 300L * $r.StartTick; $r.EndSample = 300L * $r.EndTick; $r
    }
}
enum HuntTensorLayout { ChannelFrame; FrameChannel }
class HuntTensorGeometry {
    [object] $Descriptor; [object] $Clock; [int] $Channels; [int] $Frames; [HuntTensorLayout] $Layout
}
class HuntTensorChannelMoment {
    [HuntTensorGeometry] $Geometry; [int] $Channel; [int] $StartFrame; [int] $EndFrame
    [double] $Mean; [double] $Variance; [double] $Minimum; [double] $Maximum
}
function Measure-HuntTensorChannel {
    param([Parameter(Mandatory)][HuntTensorGeometry]$Geometry, [int]$StartFrame = 0, [int]$EndFrame = -1, [int[]]$Channel = @())
    if ($null -eq $Geometry.Descriptor -or $null -eq $Geometry.Clock -or $Geometry.Channels -le 0 -or $Geometry.Frames -le 0) { throw 'Unresolved tensor geometry' }
    if ($EndFrame -eq -1) { $EndFrame = $Geometry.Frames }
    if ($StartFrame -lt 0 -or $EndFrame -le $StartFrame -or $EndFrame -gt $Geometry.Frames) { throw 'Invalid interval on tensor native clock' }
    if (!$Channel.Length) { $Channel = [int[]]::new($Geometry.Channels); for ($c = 0; $c -lt $Channel.Length; $c++) { $Channel[$c] = $c } }
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($c in $Channel) { if ($c -lt 0 -or $c -ge $Geometry.Channels -or !$seen.Add($c)) { throw 'Invalid or duplicate tensor channel' } }
    $buffer = $Geometry.Descriptor.Read()
    if ($buffer -isnot [Array] -or $buffer.Rank -ne 1 -or $buffer.LongLength -ne [long]$Geometry.Channels * $Geometry.Frames) { throw 'Tensor extent does not match verified axes' }
    foreach ($c in $Channel) {
        $m = [HuntTensorChannelMoment]::new(); $m.Geometry = $Geometry; $m.Channel = $c; $m.StartFrame = $StartFrame; $m.EndFrame = $EndFrame
        $m.Minimum = [double]::PositiveInfinity; $m.Maximum = [double]::NegativeInfinity; $ss = 0.0; $n = 0
        for ($t = $StartFrame; $t -lt $EndFrame; $t++) {
            $i = if ($Geometry.Layout -eq [HuntTensorLayout]::ChannelFrame) { [long]$c * $Geometry.Frames + $t } else { [long]$t * $Geometry.Channels + $c }
            $v = [double]$buffer[$i]; if (![double]::IsFinite($v)) { throw 'Nonfinite observation; do not fabricate moments' }
            $n++; $d = $v - $m.Mean; $m.Mean += $d / $n; $ss += $d * ($v - $m.Mean); $m.Minimum = [Math]::Min($m.Minimum, $v); $m.Maximum = [Math]::Max($m.Maximum, $v)
        }
        $m.Variance = $ss / $n; $m
    }
}

# ==============================================================================
# 7. Synthetic Verification Suite (All Fixes + Consolidated Tests)
# ==============================================================================
enum HuntFixtureContext { First; Second }
enum HuntFixtureFamily { SimulatedA; SimulatedB; SimulatedC }
class HuntFixtureExecution {
    [int] $Index; [double] $State; [double] $Nuisance; [double] $Response; [double] $Derived; [double] $HiddenLatent; [HuntFixtureContext] $Environment
}
class HuntFixture {
    [HuntAxis] $State; [HuntAxis] $Nuisance; [HuntAxis] $Response; [HuntAxis] $Derived; [HuntAxis] $HiddenLatent
    [Random] $Random = [Random]::new(741103); [int] $Next
    HuntFixture() {
        $this.State = [HuntAxis]::new(); $this.State.Name = 'state'; $this.State.Units = 'synthetic state'; $this.State.SemanticMember = [HuntFixtureExecution].GetProperty('State')
        $this.Nuisance = [HuntAxis]::new(); $this.Nuisance.Name = 'nuisance'; $this.Nuisance.Units = 'synthetic state'; $this.Nuisance.SemanticMember = [HuntFixtureExecution].GetProperty('Nuisance')
        $this.Response = [HuntAxis]::new(); $this.Response.Name = 'response'; $this.Response.Units = 'synthetic response'; $this.Response.SemanticMember = [HuntFixtureExecution].GetProperty('Response')
        $this.Derived = [HuntAxis]::new(); $this.Derived.Name = 'derived'; $this.Derived.Units = 'synthetic secondary response'; $this.Derived.SemanticMember = [HuntFixtureExecution].GetProperty('Derived')
        $this.HiddenLatent = [HuntAxis]::new(); $this.HiddenLatent.Name = 'hidden_latent'; $this.HiddenLatent.Units = 'unlocked capability axis'; $this.HiddenLatent.SemanticMember = [HuntFixtureExecution].GetProperty('HiddenLatent')
    }
    [HuntCase] NewCase([bool]$Changed, [HuntFixtureContext]$Context) {
        $this.Next++; $e = [HuntFixtureExecution]::new(); $e.Index = $this.Next; $e.Environment = $Context
        $e.State = 2 + 8 * $this.Random.NextDouble(); $e.Nuisance = 20 * $this.Random.NextDouble() - 10
        if ($Changed -and $Context -eq [HuntFixtureContext]::Second) { $e.Response = -1.25 * $e.State + 24 } else { $e.Response = 2.75 * $e.State + 4 }
        $e.Derived = 0.5 * $e.Response - 3
        $e.HiddenLatent = 1.8 * $e.State - 2.0
        $root = [HuntOrigin]::new(); $root.Source = $e; $root.EvidenceFamily = [HuntFixtureFamily]($e.Index % 3)
        $block = [HuntBlock]::new(); $block.Owner = $e; $block.Identity = 'synthetic-' + $e.Index; $block.Roots = @($root)
        $c = [HuntCase]::new(); $c.Referent = $e; $c.Context = $Context; $c.Block = $block; $c.Synthetic = $true
        $a = [HuntReading]::new(); $a.Axis = $this.State; $a.Observation = $e; $a.Coordinate = $e; $a.Value = $e.State
        $b = [HuntReading]::new(); $b.Axis = $this.Nuisance; $b.Observation = $e; $b.Coordinate = $e; $b.Value = $e.Nuisance
        $d = [HuntReading]::new(); $d.Axis = $this.Response; $d.Observation = $e; $d.Coordinate = $e; $d.Value = $e.Response
        $z = [HuntReading]::new(); $z.Axis = $this.Derived; $z.Observation = $e; $z.Coordinate = $e; $z.Value = $e.Derived
        $c.Readings = @($a, $b, $d, $z); return $c
    }
    [HuntCase[]] Batch([int]$N, [bool]$Changed) {
        $arr = [HuntCase[]]::new($N); for ($i = 0; $i -lt $N; $i++) { $arr[$i] = $this.NewCase($Changed, [HuntFixtureContext]($i % 2)) }; return $arr
    }
}
function Assert-Hunt([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
class HuntFixtureBuffer { [float[]] $Values; [float[]] Read() { return $this.Values } }

function New-HuntEphemeralTestHandle {
    param([HuntSession]$Session)
    $localObj = [HuntFixtureExecution]::new()
    $localObj.State = 5.5
    $null = $Session.Attach($localObj)
    return [HuntReproducibleHandle]::new('pin:state=5.5', $localObj, { $r = [HuntFixtureExecution]::new(); $r.State = 5.5; return $r })
}

function Test-HuntBufferProjection {
    $buf = [HuntFixtureBuffer]::new(); $buf.Values = @(1, 3, 5, 7, 9, 11)
    $g = [HuntTensorGeometry]::new(); $g.Descriptor = $buf; $g.Clock = [object]::new(); $g.Frames = 3; $g.Channels = 2; $g.Layout = [HuntTensorLayout]::ChannelFrame
    $m = @(Measure-HuntTensorChannel $g)
    Assert-Hunt ($m.Count -eq 2 -and $m[0].Mean -eq 3 -and $m[1].Mean -eq 9 -and [Math]::Abs($m[0].Variance - 8 / 3.0) -lt 1e-12) 'Channel-major moment projection failed'
    $buf2 = [HuntFixtureBuffer]::new(); $buf2.Values = @(1, 7, 3, 9, 5, 11)
    $g2 = [HuntTensorGeometry]::new(); $g2.Descriptor = $buf2; $g2.Clock = $g.Clock; $g2.Frames = 3; $g2.Channels = 2; $g2.Layout = [HuntTensorLayout]::FrameChannel
    $m2 = @(Measure-HuntTensorChannel $g2)
    Assert-Hunt ($m2[0].Mean -eq $m[0].Mean -and $m2[1].Mean -eq $m[1].Mean -and [object]::ReferenceEquals($m2[0].Geometry.Descriptor, $buf2)) 'Frame-major projection or source identity failed'
    Write-Host 'Projection verification: both tensor layouts, source identity and population moments passed'
}

function Test-HuntAdmissionControls {
    $f = [HuntFixture]::new(); $s = [HuntSession]::new(); $s.Synthetic = $true
    $train = $f.Batch(24, $false); $held = $f.Batch(24, $false)
    $candidates = @(Find-HuntPattern $s $train @($f.State) @($f.Response) 1e-7)
    $rejected = $false; try { $null = Start-HuntJudgment $s $candidates $held } catch { $rejected = $_.Exception.Message.Contains('Held-out target present') }
    Assert-Hunt $rejected 'Target-bearing recognition input accepted'
    $onlyOne = [System.Collections.Generic.List[HuntCase]]::new(); $same = $held[0].Block
    foreach ($c in $held) { $c.Block = $same; $onlyOne.Add($c) }
    $judged = @(Invoke-HuntJudgment $s $candidates $onlyOne.ToArray())
    Assert-Hunt ($judged[0].Current.IndependentBlocks -eq 1 -and $judged[0].Current.Reliance -eq [HuntReliance]::Insufficient) 'Pseudoreplication passed admission'
    $bad = $f.NewCase($false, [HuntFixtureContext]::First); $o = [HuntOrigin]::new(); $o.Source = $bad.Block.Roots[0].Source
    $o.EvidenceFamily = [HuntFixtureFamily](([int]$bad.Block.Roots[0].EvidenceFamily + 1) % 3); $bad.Block.Roots += @($o)
    $rejected = $false; try { Assert-HuntCases @($bad) $true } catch { $rejected = $_.Exception.Message.Contains('Same root counted') }
    Assert-Hunt $rejected 'Provenance relabeling accepted'
    Write-Host 'Admission controls: target leakage, pseudoreplication, and duplicate-root family alias rejected'
}

function Test-StudentPerceptHunt {
    $f = [HuntFixture]::new(); $s = [HuntSession]::new(); $s.Synthetic = $true
    $train = $f.Batch(48, $false); $validation = $f.Batch(48, $false)
    $proposals = @(Find-HuntPattern $s $train @($f.State, $f.Nuisance) @($f.Response) 1e-7)
    $judged = @(Invoke-HuntJudgment $s $proposals $validation)
    $admitted = [System.Collections.Generic.List[HuntPattern]]::new(); foreach ($p in $judged) { if ($p.Current.Reliance -eq [HuntReliance]::SyntheticAdmitted) { $admitted.Add($p) } }
    Assert-Hunt ($admitted.Count -eq 1) 'Expected one supported pattern, not nuisance association'
    $p = $admitted[0]; Assert-Hunt ([object]::ReferenceEquals($p.InputAxis, $f.State)) 'Incorrect discovery'
    Assert-Hunt ($p.LoweredReady -and $p.LoweredVerifiedCases -eq $validation.Count -and $p.ExecutionTier -eq [HuntExecutionTier]::CompiledExpression) 'Tier-2 Expression lowering failed strict parity verification'

    # Strict parity gate checks: must reject null, empty, and non-matching referent types
    Assert-Hunt (!$p.TryCompileAndVerifyLowered($null)) 'Null parity cohort must NOT succeed'
    Assert-Hunt (!$p.TryCompileAndVerifyLowered(@())) 'Zero-length parity cohort must NOT succeed'
    Assert-Hunt ($p.TryCompileAndVerifyLowered($validation)) 'Re-verification on real cohort failed'

    $historical = $p.Current
    $near = $f.NewCase($true, [HuntFixtureContext]::Second); $prediction = When-HuntPattern $p (New-HuntInput $near $p.OutputAxis)
    $outcome = Reconsider-HuntPattern $s $prediction $near
    Assert-Hunt ($outcome.OutsideBound -and $p.Current.Reliance -eq [HuntReliance]::Demoted -and !$p.LoweredReady -and $p.ExecutionTier -eq [HuntExecutionTier]::ReflectiveSma -and !$prediction.IsCurrent()) 'Demotion/lowered withdrawal failed'
    Assert-Hunt ([object]::ReferenceEquals($historical, $p.History[1])) 'Historical judgment identity changed'
    Assert-Hunt ($null -eq (When-HuntPattern $p (New-HuntInput $near $p.OutputAxis))) 'Demoted recognition still active'

    $newTrain = $f.Batch(64, $true); $newHoldout = $f.Batch(64, $true)
    $revised = @(Find-HuntPattern $s $newTrain @($f.State, $f.Nuisance) @($f.Response) 1e-7 -Specialize -Predecessor $p)
    $rejudged = @(Invoke-HuntJudgment $s $revised $newHoldout)
    $accommodated = [System.Collections.Generic.List[HuntPattern]]::new(); foreach ($q in $rejudged) { if ($q.Current.Reliance -eq [HuntReliance]::SyntheticAdmitted) { $accommodated.Add($q) } }
    Assert-Hunt ($accommodated.Count -eq 2) 'Expected two independently validated conditional patterns'
    foreach ($q in $accommodated) { Assert-Hunt ([object]::ReferenceEquals($q.Predecessor, $p)) 'Lost developmental reference' }

    $fresh = $f.Batch(24, $true); $calls = 0
    foreach ($c in $fresh) {
        $matches = 0
        foreach ($q in $accommodated) {
            $pred = When-HuntPattern $q (New-HuntInput $c $q.OutputAxis)
            if ($null -ne $pred) { $matches++; $calls++; $o = Ergo-HuntOutcome $pred $c; Assert-Hunt (!$o.OutsideBound) 'Fresh scoped recognition failed' }
        }
        Assert-Hunt ($matches -eq 1) 'Scope ambiguity'
    }

    $secondTrain = $f.Batch(64, $true); $secondHoldout = $f.Batch(64, $true)
    $secondProps = @(Find-HuntPattern $s $secondTrain @($f.Response, $f.Nuisance) @($f.Derived) 1e-7)
    $secondary = @(Invoke-HuntJudgment $s $secondProps $secondHoldout)
    $second = $null; foreach ($candidate in $secondary) { if ($candidate.Current.Reliance -eq [HuntReliance]::SyntheticAdmitted) { $second = $candidate } }
    Assert-Hunt ($null -ne $second -and [object]::ReferenceEquals($second.InputAxis, $f.Response)) 'Second relation not acquired'
    $compositions = @(foreach ($q in $accommodated) { Join-HuntPattern $q $second 1e-7 })
    $compoundJudged = @(Invoke-HuntJudgment $s $compositions ($f.Batch(96, $true)))
    $index = [HuntRecognitionIndex]::new()
    foreach ($q in $compoundJudged) { Assert-Hunt ($q.Current.Reliance -eq [HuntReliance]::SyntheticAdmitted) 'Composition failed fresh judgment'; $index.Add($q) }

    $indexed = 0
    foreach ($c in $f.Batch(32, $true)) {
        $inputOnly = New-HuntInput (New-HuntInput $c $f.Derived) $f.Response
        $nom = $index.Nominate($inputOnly); Assert-Hunt ($nom.Length -eq 1) 'Index did not nominate exactly the applicable compound'
        $pred = When-HuntPattern $nom[0] $inputOnly; $o = Ergo-HuntOutcome $pred $c; Assert-Hunt (!$o.OutsideBound) 'Compound recognition failed without intermediate'; $indexed++
    }
    Assert-Hunt ($index.CandidateVisits -eq 32) 'Index examined more than one compound per case'

    $bad = $f.NewCase($false, [HuntFixtureContext]::Second)
    $badParent = $null; foreach ($q in $accommodated) { if ($q.Context -eq [HuntFixtureContext]::Second) { $badParent = $q } }
    $badPrediction = When-HuntPattern $badParent (New-HuntInput $bad $f.Response)
    $badResult = Reconsider-HuntPattern $s $badPrediction $bad
    Assert-Hunt ($badResult.OutsideBound) 'Expected later constituent failure'
    Assert-Hunt ($index.Nominate((New-HuntInput (New-HuntInput $bad $f.Derived) $f.Response)).Length -eq 0) 'Invalid constituent still authorizes dependent recognition'
    $good = $f.NewCase($true, [HuntFixtureContext]::First)
    Assert-Hunt ($index.Nominate((New-HuntInput (New-HuntInput $good $f.Derived) $f.Response)).Length -eq 1) 'Unrelated context incorrectly disabled'

    # 1) Child-scope WeakReference + CWT GC test (no caller stack slot pinning!)
    $handle = New-HuntEphemeralTestHandle $s
    [GC]::Collect(2, [GCCollectionMode]::Forced, $true, $true)
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect(2, [GCCollectionMode]::Forced, $true, $true)
    $rebuilt = $handle.GetOrRematerialize()
    Assert-Hunt ($rebuilt[1] -eq $true -and $rebuilt[0].State -eq 5.5) 'Weak handle rematerialization failed after child scope exit + forced GC'

    # 2) Retrospective discovery under strict holdout judgment
    $frozenDisc = $f.Batch(48, $true); $frozenHold = $f.Batch(48, $true)
    foreach ($c in ($frozenDisc + $frozenHold)) {
        $hr = [HuntReading]::new(); $hr.Axis = $f.HiddenLatent; $hr.Observation = $c.Referent; $hr.Coordinate = $c.Referent; $hr.Value = $c.Referent.HiddenLatent
        $c.Readings = @($c.Readings) + @($hr)
    }
    $retro = @(Invoke-HuntCapabilityRevisit $s 'ExtractHiddenLatent' $frozenDisc $frozenHold $f.HiddenLatent $f.State 1e-7)
    Assert-Hunt ($retro.Count -eq 1 -and $retro[0].Current.Reliance -eq [HuntReliance]::SyntheticAdmitted) 'Retrospective capability discovery failed'

    # 3) Tier-3 PSC Lowering Hook simulation (.GetNewClosure()) + parity gate
    Register-HuntPscLowerer $s {
        param([HuntPattern]$pat)
        $m = $pat.Slope; $b = $pat.Offset; $name = $pat.InputAxis.SemanticMember.Name
        return [Func[object, double]]({ param($ref) return ($m * [double]($ref.$name) + $b) }.GetNewClosure())
    }
    $promoted = Promote-HuntPatternToPsc $s $retro[0] $frozenHold
    Assert-Hunt ($promoted -and $retro[0].ExecutionTier -eq [HuntExecutionTier]::ExternalDelegate) 'External delegate parity failed'

    # 4) Full-Fidelity PSNL Export -> SMA ParseInput -> Fresh-Scope Reconstruction
    $psnl = Export-HuntPsnlScript $s
    $tok = $null; $err = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($psnl, [ref]$tok, [ref]$err)
    Assert-Hunt ($err.Count -eq 0) "PSNL export failed SMA parsing: $($err | Out-String)"
    $liveAxes = [Collections.Generic.Dictionary[guid,HuntAxis]]::new()
    foreach ($c in $frozenHold) { foreach ($r in $c.Readings) { $liveAxes[$r.Axis.Identity] = $r.Axis } }
    $bundle = & ([scriptblock]::Create($psnl)) -LiveAxes $liveAxes
    $restoredPatterns = $bundle[0]; $restoredReveries = $bundle[1]; $restoredCases = $bundle[2]; $restoredJudgments = $bundle[3]
    Assert-Hunt ($restoredPatterns.Count -eq $s.Patterns.Count) 'PSNL restored pattern count mismatch'
    Assert-Hunt ($restoredReveries.Count -eq $s.Reveries.Count) 'PSNL restored reverie count mismatch'
    Assert-Hunt ($restoredCases.Count -gt 0 -and $restoredJudgments.Count -gt 0) 'PSNL did not preserve evidentiary history'
    Assert-Hunt ($restoredPatterns[0].Identity -eq $s.Patterns[0].Identity) 'PSNL lost pattern Guid identity'
    Assert-Hunt ($restoredPatterns[0].Discovery.Count -eq $s.Patterns[0].Discovery.Count) 'PSNL lost Discovery cohort'
    Assert-Hunt ($restoredPatterns[0].Counterexamples.Count -eq $s.Patterns[0].Counterexamples.Count) 'PSNL lost Counterexamples'
    Assert-Hunt ($restoredPatterns[0].History.Count -eq $s.Patterns[0].History.Count) 'PSNL lost full Judgment History'
    Assert-Hunt ($restoredPatterns[0].History[1].Evidence.Count -gt 0) 'PSNL lost Judgment.Evidence'
    Assert-Hunt ([object]::ReferenceEquals($restoredCases[0].Referent, $restoredCases[0].Block.Owner)) 'PSNL broke shared ReferenceEquals on external source handles'
    Assert-Hunt (!$restoredPatterns[0].LoweredReady) 'Restored pattern must stay ReflectiveSma until live ParityCohort verifies lowering'
    Assert-Hunt (!$restoredPatterns[0].TryCompileAndVerifyLowered($restoredCases)) 'Source-clean HuntSourceCleanReference cohort must NOT satisfy live referent lowering'

    # Verify Trigger reference preserved on demoted dependent pattern
    $demotedChild = $null
    foreach ($rp in $restoredPatterns) { if ($rp.Constituents.Count -gt 0 -and $rp.Current.Reliance -eq [HuntReliance]::Demoted) { $demotedChild = $rp; break } }
    Assert-Hunt ($null -ne $demotedChild -and $null -ne $demotedChild.Current.Trigger) 'PSNL lost Judgment.Trigger reference on demoted dependent'

    # Verify re-lowering succeeds once live HuntFixtureExecution cases are supplied
    $liveRelowered = $restoredPatterns[-1].TryCompileAndVerifyLowered($frozenHold)
    Assert-Hunt ([object]::ReferenceEquals($restoredPatterns[-1].InputAxis,$f.HiddenLatent)) 'Reconstruction split the live input axis'
    Assert-Hunt ($liveRelowered -and $restoredPatterns[-1].LoweredReady -and $restoredPatterns[-1].LoweredVerifiedCases -eq $frozenHold.Count) 'Live re-lowering on restored pattern failed'

    Write-Host ($s.OpenPerceptField() | Format-List | Out-String)
    Write-Host ("PSNL roundtrip verified: patterns={0}, reveries={1}, cases={2}, judgments={3}" -f $restoredPatterns.Count, $restoredReveries.Count, $restoredCases.Count, $restoredJudgments.Count)
    return $s
}

if (!$Library) {
    $ErrorActionPreference = 'Stop'
    Test-HuntBufferProjection
    Test-HuntAdmissionControls
    $null = Test-StudentPerceptHunt
}
