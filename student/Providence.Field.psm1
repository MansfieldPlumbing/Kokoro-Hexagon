#requires -Version 7.4
# Providence: incremental reflection-based structural perception over canonical CLR referents.
# This module does not claim acoustic, linguistic, or causal discoveries from a graph join.

using namespace System.Collections.Generic
using namespace System.Reflection

class ProvidenceBearing {
    [object] $Owner
    [object] $Referent
    [string] $OwnerKey
    [string] $ReferentKey
    [string] $CapabilityKey
    [string] $SourceFamily
    [DateTime] $ObservedAt
    [bool] $Valid = $true
}
class ProvidencePercept {
    [string] $Key
    [object] $Owner
    [object] $Referent
    [string] $OwnerKey
    [string] $ReferentKey
    [List[ProvidenceBearing]] $Bearings = [List[ProvidenceBearing]]::new()
    # Structural joins are observed evidence, not acquired linguistic percepts.
    [string] $Reliance = 'ObservedStructural'
    [bool] $Acquired = $false
    [long] $Version = 0
    [string] $Scope = 'Observed CLR reference identity in the current source graph'
    [void] Reconsider([Dictionary[string,ProvidenceCapability]] $capabilities) {
        $valid = 0
        foreach ($bearing in $this.Bearings) {
            $capability = $null
            if ($capabilities.TryGetValue($bearing.CapabilityKey,[ref]$capability) -and $capability.Valid) {
                $bearing.Valid = $true; $valid++
            } else { $bearing.Valid = $false }
        }
        $next = if ($valid -gt 0) { 'ObservedStructural' } else { 'Withdrawn' }
        if ($this.Reliance -cne $next) { $this.Reliance=$next; $this.Version++ }
    }
}
class ProvidenceReverie {
    [string] $Key
    [string] $OwnerKey
    [string] $MissingCapability
    [string] $Reason
    [string] $Status = 'Blocked'
    [type] $NeededType
    [object] $Owner
    [object] $Resolution
    [string] $ResolutionCapability
    [long] $Version = 0
}
class ProvidenceCapability {
    [string] $Key
    [type] $InputType
    [type] $OutputType
    [PropertyInfo[]] $Path = @()
    [string[]] $Dependencies = @()
    [string] $Kind = 'ReflectedMember'
    [bool] $Valid = $true
    [bool] $ObservedOnRealReferent = $false
    [long] $Applications = 0
    [long] $Successful = 0
    [long] $Failures = 0
    [long] $ElapsedTicks = 0
    [int] $Depth = 1
}
class ProvidenceWork {
    [object] $Referent
    [string] $CapabilityKey
    [ProvidenceWork] static Create([object]$target,[string]$key) {
        $w=[ProvidenceWork]::new();$w.Referent=$target;$w.CapabilityKey=$key;return $w
    }
}
class ProvidenceField {
    [int] $MaxDepth = 3
    [int] $MaxCapabilities = 6000
    [long] $MaxReferents = 250000
    [Dictionary[string,ProvidenceCapability]] $Capabilities = [Dictionary[string,ProvidenceCapability]]::new([StringComparer]::Ordinal)
    [Dictionary[string,ProvidenceReverie]] $Reveries = [Dictionary[string,ProvidenceReverie]]::new([StringComparer]::Ordinal)
    [Dictionary[object,List[ProvidenceReverie]]] $RequirementsByOwner = [Dictionary[object,List[ProvidenceReverie]]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    [Dictionary[string,ProvidencePercept]] $Percepts = [Dictionary[string,ProvidencePercept]]::new([StringComparer]::Ordinal)
    [Dictionary[string,string]] $FileObservations = [Dictionary[string,string]]::new([StringComparer]::Ordinal)
    [Dictionary[object,string]] $ReferentKeys = [Dictionary[object,string]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    [Dictionary[object,string]] $Families = [Dictionary[object,string]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
    [Dictionary[string,object]] $ByKey = [Dictionary[string,object]]::new([StringComparer]::Ordinal)
    [Dictionary[string,List[ProvidencePercept]]] $PendingByKey = [Dictionary[string,List[ProvidencePercept]]]::new([StringComparer]::Ordinal)
    [Dictionary[string,List[string]]] $PendingWorkByKey = [Dictionary[string,List[string]]]::new([StringComparer]::Ordinal)
    [Dictionary[type,List[object]]] $ByType = [Dictionary[type,List[object]]]::new()
    [Queue[object]] $NewReferents = [Queue[object]]::new()
    [Queue[ProvidenceWork]] $Investigations = [Queue[ProvidenceWork]]::new()
    [HashSet[string]] $Scheduled = [HashSet[string]]::new([StringComparer]::Ordinal)
    [HashSet[string]] $ObservedPairs = [HashSet[string]]::new([StringComparer]::Ordinal)
    [HashSet[string]] $KnownCapabilities = [HashSet[string]]::new([StringComparer]::Ordinal)
    [long] $Observations = 0
    [long] $FilesCovered = 0
    [long] $BytesVerified = 0
    [long] $DistinctJoinPercepts = 0
    [long] $AcquiredCompositions = 0
    [long] $ActualCalls = 0
    [long] $Errors = 0
    [long] $RepeatedObservationsAvoided = 0
    [string] $State = 'Active'
    [bool] $PreferFocused = $false

    [string] ObjectKey([object]$o) {
        $key=''
        if ($this.ReferentKeys.TryGetValue($o,[ref]$key)) { return $key }
        throw 'Referent has not been registered'
    }
    [string] QualifiedKey([object]$o,[string]$suggested) {
        # Original source IDs and execution coordinates outrank incidental
        # traversal order. Borrowed CLR objects retain reference identity.
        switch ($o.GetType().Name) {
            'StudentSourceUnit' {
                if($o.Id){return 'source/'+[string]$o.Id}
            }
            'StudentSentenceEvidence' {
                if($o.Document -and $o.Document.Source){
                    return 'sentence/'+$o.Document.Source.Id+'/'+$o.Index
                }
            }
            'StudentTeacherObservation' {
                if($o.Document -and $o.Document.Source){
                    return 'teacher/'+$o.Document.Source.Id+'/'+$o.Start+'/'+$o.Length
                }
            }
            'StudentStockExecution' {
                if($o.Teacher -and $o.Teacher.Document){
                    return 'execution/'+$o.Teacher.Document.Source.Id+'/'+$o.Teacher.Start+'/'+
                        $o.Teacher.Length+'/'+$o.Recipe
                }
            }
            'StudentStockActivation' {
                if($o.Execution -and $o.Execution.Teacher -and $o.Execution.Teacher.Document){
                    return 'activation/'+$o.Execution.Teacher.Document.Source.Id+'/'+
                        $o.Execution.Teacher.Start+'/'+$o.Execution.Teacher.Length+'/'+
                        $o.Execution.Recipe+'/'+$o.Stage+'/'+$o.Axes+'/'+$o.Checksum
                }
            }
        }
        return $suggested
    }
    [bool] IsReferenceType([type]$t) {
        if ($null -eq $t -or $t.IsPrimitive -or $t.IsEnum -or $t.IsValueType -or $t -eq [string] -or $t -eq [object]) { return $false }
        if ($t -eq [byte[]] -or $t -eq [single[]] -or $t -eq [double[]] -or $t -eq [int[]] -or $t -eq [long[]]) { return $false }
        if ([Delegate].IsAssignableFrom($t) -or [IO.Stream].IsAssignableFrom($t)) { return $false }
        return $true
    }
    [type] ElementType([type]$t) {
        if ($t.IsArray) { return $t.GetElementType() }
        if ($t.IsGenericType) {
            foreach ($arg in $t.GetGenericArguments()) {
                if ($this.IsReferenceType($arg) -and $arg -ne [string]) { return $arg }
            }
        }
        return $t
    }
    [bool] ShouldInspect([type]$type) {
        if ($type.IsPrimitive -or $type.IsValueType -or $type -eq [string]) { return $false }
        # Limit automatic traversal to the Student's dynamically defined CLR types,
        # SMA ASTs, and actual source/semantic-bearing classes supplied by an adapter.
        if ($type.Assembly.IsDynamic) { return $true }
        if ([Management.Automation.Language.Ast].IsAssignableFrom($type)) { return $true }
        if ($type.FullName -and $type.FullName.StartsWith('System.Management.Automation.Language.',[StringComparison]::Ordinal)) { return $true }
        return $false
    }
    [bool] Register([object]$referent,[string]$key,[string]$family) {
        if ($null -eq $referent -or !$this.ShouldInspect($referent.GetType())) { return $false }
        if ($this.ReferentKeys.ContainsKey($referent)) {
            $this.RepeatedObservationsAvoided++
            return $false
        }
        $key=$this.QualifiedKey($referent,$key)
        if ($this.ReferentKeys.Count -ge $this.MaxReferents) { throw 'Configured canonical referent bound reached.' }
        if ($this.ByKey.ContainsKey($key) -and ![object]::ReferenceEquals($this.ByKey[$key],$referent)) {
            throw "Stable source key collision: $key"
        }
        $this.ReferentKeys.Add($referent,$key)
        $this.ByKey[$key]=$referent
        $claims=$null
        if($this.PendingByKey.TryGetValue($key,[ref]$claims)){
            foreach($claim in $claims){
                if($claim.OwnerKey -ceq $key){$claim.Owner=$referent}
                if($claim.ReferentKey -ceq $key){$claim.Referent=$referent}
            }
            $null=$this.PendingByKey.Remove($key)
        }
        $pendingJobs=$null
        if($this.PendingWorkByKey.TryGetValue($key,[ref]$pendingJobs)){
            foreach($capKey in $pendingJobs){$this.Schedule($referent,$capKey)}
            $null=$this.PendingWorkByKey.Remove($key)
        }
        $this.Families.Add($referent,$family)
        $type = $referent.GetType()
        if (!$this.ByType.ContainsKey($type)) { $this.ByType.Add($type,[List[object]]::new()) }
        $this.ByType[$type].Add($referent)
        $this.NewReferents.Enqueue($referent)
        foreach ($cap in $this.Capabilities.Values) {
            if ($cap.Valid -and $cap.InputType.IsAssignableFrom($type)) { $this.Schedule($referent,$cap.Key) }
        }
        return $true
    }
    [void] Schedule([object]$referent,[string]$key) {
        $cap=$null
        if (!$this.Capabilities.TryGetValue($key,[ref]$cap) -or !$cap.Valid) { return }
        if (!$cap.InputType.IsAssignableFrom($referent.GetType())) { return }
        if ($cap.Depth -gt 1) {
            $requirements=$null
            if (!$this.RequirementsByOwner.TryGetValue($referent,[ref]$requirements)) { return }
            $applicable=$false
            foreach($requirement in $requirements){
                if($requirement.Status -ceq 'Blocked' -and $requirement.NeededType -and
                    $requirement.NeededType.IsAssignableFrom($cap.OutputType)){
                    $applicable=$true
                    break
                }
            }
            if(!$applicable){return}
        }
        $token = [string][Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($referent)+'/'+$this.ObjectKey($referent)+'/'+$key
        if ($this.Scheduled.Add($token)) { $this.Investigations.Enqueue([ProvidenceWork]::Create($referent,$key)) }
    }
    [void] IntroduceCapability([ProvidenceCapability]$cap) {
        if ($this.Capabilities.ContainsKey($cap.Key) -or $this.Capabilities.Count -ge $this.MaxCapabilities) { return }
        $this.Capabilities.Add($cap.Key,$cap)
        foreach ($knownType in $this.ByType.Keys) {
            if ($cap.InputType.IsAssignableFrom($knownType)) {
                foreach ($obj in $this.ByType[$knownType]) { $this.Schedule($obj,$cap.Key) }
            }
        }
        # An available typed capability can wake a previously blocked question.
        foreach ($reverie in $this.Reveries.Values) {
            if ($reverie.Status -cne 'Blocked' -or !$reverie.Owner -or !$reverie.NeededType) { continue }
            if ($cap.InputType.IsAssignableFrom($reverie.Owner.GetType()) -and
                $reverie.NeededType.IsAssignableFrom($cap.OutputType)) {
                $this.Schedule($reverie.Owner,$cap.Key)
            }
        }
        # Compose typed property paths only after both constituents exist as actual
        # observed CLR operations. No named clock, morphology, or model target.
        if ($cap.Depth -ge $this.MaxDepth) { return }
        $existing=[ProvidenceCapability[]]@($this.Capabilities.Values)
        foreach ($other in $existing) {
            if ($other.Key -ceq $cap.Key) { continue }
            if ($this.Capabilities.Count -ge $this.MaxCapabilities) { break }
            if ($cap.Depth + $other.Depth -gt $this.MaxDepth) { continue }
            if ($other.InputType.IsAssignableFrom($cap.OutputType)) { $this.TryCompose($cap,$other) }
            if ($cap.InputType.IsAssignableFrom($other.OutputType)) { $this.TryCompose($other,$cap) }
        }
    }
    [void] TryCompose([ProvidenceCapability]$first,[ProvidenceCapability]$second) {
        if (!$first.ObservedOnRealReferent -or !$second.ObservedOnRealReferent -or !$first.Valid -or !$second.Valid) { return }
        if ($first.Depth + $second.Depth -gt $this.MaxDepth) { return }
        $path = [PropertyInfo[]]@($first.Path + $second.Path)
        if ($path.Count -gt $this.MaxDepth) { return }
        $key = 'PATH/'+$first.InputType.AssemblyQualifiedName+'/'+(($path | ForEach-Object { $_.DeclaringType.FullName + '.' + $_.Name }) -join '->')
        if ($this.Capabilities.ContainsKey($key) -or $this.Capabilities.Count -ge $this.MaxCapabilities) { return }
        $composed=[ProvidenceCapability]::new()
        $composed.Key=$key;$composed.InputType=$first.InputType;$composed.OutputType=$second.OutputType
        $composed.Path=$path;$composed.Depth=$path.Count;$composed.Kind='AcquiredComposition'
        $composed.Dependencies=[string[]]@($first.Key,$second.Key)
        $this.AcquiredCompositions++
        $this.IntroduceCapability($composed)
    }
    [void] Inspect([object]$owner) {
        $type=$owner.GetType()
        foreach ($property in $type.GetProperties([BindingFlags]'Public,Instance')) {
            if ($property.GetIndexParameters().Length -gt 0 -or !$property.CanRead) { continue }
            $out=$this.ElementType($property.PropertyType)
            if ($out -eq [object]) {
                # PowerShell class adapters often declare object-valued borrowed references.
                # Read the actual value, preserving its runtime CLR type and identity.
                $observed=$property.GetValue($owner)
                if ($null -eq $observed) { continue }
                $out=$this.ElementType($observed.GetType())
            }
            if (!$this.IsReferenceType($out) -or !$this.ShouldInspect($out)) { continue }
            $key='PATH/'+$type.AssemblyQualifiedName+'/'+$property.DeclaringType.FullName+'.'+$property.Name
            if (!$this.Capabilities.ContainsKey($key)) {
                $c=[ProvidenceCapability]::new();$c.Key=$key;$c.InputType=$type;$c.OutputType=$out;$c.Path=[PropertyInfo[]]@($property)
                $this.IntroduceCapability($c)
            }
        }
    }
    [object[]] ReadTargets([object]$owner,[PropertyInfo]$property) {
        $value=$property.GetValue($owner)
        if ($null -eq $value) { return @() }
        if ($value -is [System.Collections.IDictionary]) { return [object[]]@($value.Values) }
        if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
            $items=[List[object]]::new()
            foreach ($element in $value) {
                if ($element -is [System.Collections.DictionaryEntry]) { $element=$element.Value }
                if ($null -ne $element) { $items.Add($element) }
            }
            return $items.ToArray()
        }
        return [object[]]@($value)
    }
    [void] Execute([ProvidenceWork]$work) {
        $cap=$null
        if (!$this.Capabilities.TryGetValue($work.CapabilityKey,[ref]$cap) -or !$cap.Valid) { return }
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try {
            $nodes=[object[]]@($work.Referent)
            foreach ($property in $cap.Path) {
                $next=[List[object]]::new()
                $seen=[HashSet[object]]::new([System.Collections.Generic.ReferenceEqualityComparer]::Instance)
                foreach ($node in $nodes) {
                    if ($null -eq $node -or !$property.DeclaringType.IsAssignableFrom($node.GetType())) { continue }
                    foreach ($item in $this.ReadTargets($node,$property)) {
                        if ($seen.Add($item) -and $this.ShouldInspect($item.GetType())) { $next.Add($item) }
                    }
                }
                $nodes=$next.ToArray()
                if (!$nodes.Count) { break }
            }
            $cap.Applications++
            $this.ActualCalls++
            if ($nodes.Count -eq 0) {
                # Null properties are often legitimate. Absence without an actual
                # investigative requirement is not an independently acquired reverie.
                return
            }
            $cap.Successful++
            if (!$cap.ObservedOnRealReferent) {
                $cap.ObservedOnRealReferent=$true
                $existing=[ProvidenceCapability[]]@($this.Capabilities.Values)
                foreach ($other in $existing) {
                    if ($other.ObservedOnRealReferent -and $other.Valid -and $other.Key -cne $cap.Key) {
                        if ($other.InputType.IsAssignableFrom($cap.OutputType)) { $this.TryCompose($cap,$other) }
                        if ($cap.InputType.IsAssignableFrom($other.OutputType)) { $this.TryCompose($other,$cap) }
                    }
                }
            }
            $ownerKey=$this.ObjectKey($work.Referent)
            $family=$this.Families[$work.Referent]
            $requirements=$null
            $null=$this.RequirementsByOwner.TryGetValue($work.Referent,[ref]$requirements)
            $index=0
            foreach ($result in $nodes) {
                $id=$ownerKey+'/'+$cap.Key+'['+$index+']'
                $null=$this.Register($result,$id,$family)
                $targetKey=$this.ObjectKey($result)
                foreach($rev in $requirements){
                    if($rev.Status -cne 'Blocked' -or !$rev.Owner -or !$rev.NeededType){continue}
                    if([object]::ReferenceEquals($rev.Owner,$work.Referent) -and
                        $rev.NeededType.IsAssignableFrom($result.GetType())){
                        $rev.Status='Resolved';$rev.Resolution=$result;$rev.ResolutionCapability=$cap.Key
                        $rev.Version++
                    }
                }
                $relationKey=$ownerKey+' => '+$targetKey
                $edgeKey=$relationKey+'/'+$cap.Key
                if ($this.ObservedPairs.Add($edgeKey)) {
                    $p=$null
                    if (!$this.Percepts.TryGetValue($relationKey,[ref]$p)) {
                        $p=[ProvidencePercept]::new();$p.Key=$relationKey;$p.Owner=$work.Referent;$p.Referent=$result
                        $p.OwnerKey=$ownerKey;$p.ReferentKey=$targetKey
                        $this.Percepts.Add($relationKey,$p)
                    }
                    $prior=$null
                    foreach($candidate in $p.Bearings){
                        if($candidate.CapabilityKey -ceq $cap.Key -and $candidate.SourceFamily -ceq $family){
                            $prior=$candidate;break
                        }
                    }
                    if($prior){
                        # A persisted bearing is verified again against the real CLR graph.
                        $prior.Owner=$work.Referent;$prior.Referent=$result
                        $prior.Valid=$cap.Valid;$prior.ObservedAt=[DateTime]::UtcNow
                        $this.RepeatedObservationsAvoided++
                    } else {
                        $bearing=[ProvidenceBearing]::new();$bearing.Owner=$work.Referent;$bearing.Referent=$result
                        $bearing.OwnerKey=$ownerKey;$bearing.ReferentKey=$targetKey;$bearing.CapabilityKey=$cap.Key
                        $bearing.SourceFamily=$family;$bearing.ObservedAt=[DateTime]::UtcNow
                        $p.Bearings.Add($bearing)
                        if ($p.Bearings.Count -eq 2) { $this.DistinctJoinPercepts++ }
                        $this.Observations++
                    }
                    $p.Reconsider($this.Capabilities)
                }
                $index++
            }
        } catch {
            $cap.Failures++;$this.Errors++
            $id=$this.ObjectKey($work.Referent)+'/'+$cap.Key
            if (!$this.Reveries.ContainsKey($id)) {
                $gap=[ProvidenceReverie]::new();$gap.Key=$id;$gap.OwnerKey=$this.ObjectKey($work.Referent)
                $gap.MissingCapability=$cap.Key;$gap.Reason=$_.Exception.GetType().FullName+': '+$_.Exception.Message
                $this.Reveries.Add($id,$gap)
            }
        } finally { $cap.ElapsedTicks += $watch.ElapsedTicks }
    }
    [bool] Step() {
        $focus=$this.PreferFocused
        $this.PreferFocused=!$this.PreferFocused
        if ($focus -and $this.Investigations.Count -gt 0) {
            $this.Execute($this.Investigations.Dequeue());return $true
        }
        if ($this.NewReferents.Count -gt 0) { $this.Inspect($this.NewReferents.Dequeue());return $true }
        if ($this.Investigations.Count -gt 0) { $this.Execute($this.Investigations.Dequeue());return $true }
        return $false
    }
    [int] Advance([int]$budget) {
        $done=0
        for($n=0;$n -lt $budget;$n++) { if (!$this.Step()) { break };$done++ }
        $this.State=if($done -eq 0){'Quiescent'}else{'Active'}
        return $done
    }
    [void] Withdraw([string]$key) {
        if (!$this.Capabilities.ContainsKey($key)) { throw 'Unknown acquired capability' }
        $pending=[Queue[string]]::new();$pending.Enqueue($key)
        $visited=[HashSet[string]]::new([StringComparer]::Ordinal)
        while($pending.Count){
            $item=$pending.Dequeue()
            if(!$visited.Add($item)){continue}
            $this.Capabilities[$item].Valid=$false
            foreach($child in $this.Capabilities.Values){ if($item -cin $child.Dependencies){$pending.Enqueue($child.Key)} }
        }
        foreach($p in $this.Percepts.Values){$p.Reconsider($this.Capabilities)}
        foreach($r in $this.Reveries.Values){
            if($r.Status -ceq 'Resolved' -and $r.ResolutionCapability -and
                !$this.Capabilities[$r.ResolutionCapability].Valid){
                $r.Status='Blocked';$r.Resolution=$null;$r.Version++
            }
        }
    }
    [void] Restore([string]$key) {
        if (!$this.Capabilities.ContainsKey($key)) { throw 'Unknown acquired capability' }
        $this.Capabilities[$key].Valid=$true
        $changed=$true
        while($changed){
            $changed=$false
            foreach($cap in $this.Capabilities.Values){
                if($cap.Valid -or !$cap.Dependencies.Count){continue}
                $all=$true;foreach($dependency in $cap.Dependencies){if(!$this.Capabilities[$dependency].Valid){$all=$false;break}}
                if($all){$cap.Valid=$true;$changed=$true}
            }
        }
        foreach($p in $this.Percepts.Values){$p.Reconsider($this.Capabilities)}
        foreach($type in $this.ByType.Keys){
            foreach($obj in $this.ByType[$type]){
                foreach($cap in $this.Capabilities.Values){if($cap.Valid -and $cap.InputType.IsAssignableFrom($type)){$this.Schedule($obj,$cap.Key)}}
            }
        }
    }
    [ProvidenceReverie] Require([object]$owner,[type]$neededType,[string]$reason) {
        if(!$this.ReferentKeys.ContainsKey($owner)){throw 'Requirement owner must be an observed canonical referent.'}
        if(!$this.IsReferenceType($neededType)){throw 'Requirement must identify a CLR referent type.'}
        $id=$this.ObjectKey($owner)+'/needs/'+$neededType.FullName+'/'+$reason
        $r=$null
        if(!$this.Reveries.TryGetValue($id,[ref]$r)){
            $r=[ProvidenceReverie]::new();$r.Key=$id;$r.OwnerKey=$this.ObjectKey($owner)
            $r.NeededType=$neededType;$r.Reason=$reason
            $this.Reveries.Add($id,$r)
        }
        if([object]::ReferenceEquals($r.Owner,$owner)){return $r}
        $r.Owner=$owner
        if(!$this.RequirementsByOwner.ContainsKey($owner)){
            $this.RequirementsByOwner.Add($owner,[List[ProvidenceReverie]]::new())
        }
        $this.RequirementsByOwner[$owner].Add($r)
        foreach($c in $this.Capabilities.Values){
            if($c.Valid -and $c.InputType.IsAssignableFrom($owner.GetType()) -and
                $neededType.IsAssignableFrom($c.OutputType)){$this.Schedule($owner,$c.Key)}
        }
        return $r
    }
    [object] Status() {
        $withdrawn=0;foreach($p in $this.Percepts.Values){if($p.Reliance -ceq 'Withdrawn'){$withdrawn++}}
        $acquired=0;foreach($p in $this.Percepts.Values){if($p.Acquired){$acquired++}}
        return [pscustomobject]@{ State=$this.State; Referents=$this.ReferentKeys.Count; StructuralRelations=$this.Percepts.Count
            AcquiredPercepts=$acquired
            MultiplePathRelations=$this.DistinctJoinPercepts; Capabilities=$this.Capabilities.Count; AcquiredCompositions=$this.AcquiredCompositions
            Reveries=$this.Reveries.Count; Withdrawn=$withdrawn; Observations=$this.Observations; Calls=$this.ActualCalls
            PendingRoots=$this.NewReferents.Count; PendingInvestigations=$this.Investigations.Count; FilesCovered=$this.FilesCovered
            BytesVerified=$this.BytesVerified; RepeatedObservationsAvoided=$this.RepeatedObservationsAvoided; Errors=$this.Errors }
    }
}

function New-ProvidenceField { [CmdletBinding()]param() return [ProvidenceField]::new() }


# Resolve a source-defined PowerShell class by semantic CLR full name when its
# generated assembly name changes across processes. Never deserialize as text.
function Resolve-ProvidenceType {
    param([Parameter(Mandatory)][string]$Identity)
    $type=[type]::GetType($Identity,$false)
    if($type){return $type}
    $fullName=$Identity.Split(',')[0].Trim()
    foreach($assembly in [AppDomain]::CurrentDomain.GetAssemblies()){
        $candidate=$assembly.GetType($fullName,$false)
        if($candidate){return $candidate}
    }
    throw "CLR type unavailable in this process: $fullName; import its actual source module first"
}

function Save-ProvidenceField {
    [CmdletBinding()]param([Parameter(Mandatory)][ProvidenceField]$Field,[Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $directory=[IO.Path]::GetDirectoryName($full);$null=[IO.Directory]::CreateDirectory($directory)
    $tmp=$full+'.'+[guid]::NewGuid().ToString('N')+'.partial'
    $writer=[IO.BinaryWriter]::new([IO.File]::Open($tmp,[IO.FileMode]::CreateNew))
    try {
        $writer.Write('Providence-StructuralField/2')
        $writer.Write($Field.FileObservations.Count)
        foreach($entry in $Field.FileObservations.GetEnumerator()){$writer.Write($entry.Key);$writer.Write($entry.Value)}
        $writer.Write($Field.Capabilities.Count)
        foreach($cap in $Field.Capabilities.Values){
            $writer.Write($cap.Key)
            $writer.Write($cap.InputType.FullName)
            $writer.Write($cap.OutputType.FullName)
            $writer.Write($cap.Path.Length)
            foreach($member in $cap.Path){$writer.Write($member.DeclaringType.FullName);$writer.Write($member.Name)}
            $writer.Write($cap.Valid);$writer.Write($cap.ObservedOnRealReferent)
            $writer.Write($cap.Applications);$writer.Write($cap.Successful);$writer.Write($cap.Failures);$writer.Write($cap.ElapsedTicks)
            $writer.Write($cap.Dependencies.Length)
            foreach($depend in $cap.Dependencies){$writer.Write($depend)}
        }
        $writer.Write($Field.Percepts.Count)
        foreach($p in $Field.Percepts.Values){
            $writer.Write($p.OwnerKey);$writer.Write($p.ReferentKey);$writer.Write($p.Reliance)
            $writer.Write($p.Acquired);$writer.Write($p.Version);$writer.Write($p.Scope)
            $writer.Write($p.Bearings.Count)
            foreach($b in $p.Bearings){$writer.Write($b.CapabilityKey);$writer.Write($b.SourceFamily);$writer.Write($b.Valid)}
        }
        $writer.Write($Field.Reveries.Count)
        foreach($r in $Field.Reveries.Values){
            $writer.Write($r.Key);$writer.Write($r.OwnerKey);$writer.Write([string]$r.MissingCapability)
            $writer.Write($r.Reason);$writer.Write($r.Status);$writer.Write($r.Version)
            $writer.Write([string]$r.ResolutionCapability)
            $writer.Write($(if($r.NeededType){$r.NeededType.FullName}else{''}))
        }
        $pending=[List[object[]]]::new()
        foreach($job in $Field.Investigations){
            if($Field.ReferentKeys.ContainsKey($job.Referent)){
                $pending.Add([object[]]@($Field.ObjectKey($job.Referent),$job.CapabilityKey))
            }
        }
        foreach($kv in $Field.PendingWorkByKey.GetEnumerator()){
            foreach($capKey in $kv.Value){$pending.Add([object[]]@($kv.Key,$capKey))}
        }
        $writer.Write($pending.Count)
        foreach($entry in $pending){$writer.Write([string]$entry[0]);$writer.Write([string]$entry[1])}
        $writer.Flush();$writer.BaseStream.Flush($true)
    } finally {$writer.Dispose()}
    [IO.File]::Move($tmp,$full,$true)
}

function Import-ProvidenceField {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path,[switch]$CapabilitiesOnly)
    $field=[ProvidenceField]::new()
    $reader=[IO.BinaryReader]::new([IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path))
    try {
        if($reader.ReadString() -cne 'Providence-StructuralField/2'){
            throw 'Unsupported field version; do not silently flatten or discard prior evidence'
        }
        $files=$reader.ReadInt32()
        for($i=0;$i -lt $files;$i++){$key=$reader.ReadString();$field.FileObservations[$key]=$reader.ReadString()}
        $count=$reader.ReadInt32()
        for($i=0;$i -lt $count;$i++){
            $c=[ProvidenceCapability]::new();$c.Key=$reader.ReadString()
            $c.InputType=Resolve-ProvidenceType $reader.ReadString()
            $c.OutputType=Resolve-ProvidenceType $reader.ReadString()
            $n=$reader.ReadInt32();$members=[List[PropertyInfo]]::new()
            for($j=0;$j -lt $n;$j++){
                $decl=Resolve-ProvidenceType $reader.ReadString();$memberName=$reader.ReadString()
                $member=$decl.GetProperty($memberName,[BindingFlags]'Public,Instance')
                if(!$member){throw "Missing method contract $($decl.FullName).$memberName"}
                $members.Add($member)
            }
            $c.Path=$members.ToArray();$c.Depth=$c.Path.Count
            $c.Valid=$reader.ReadBoolean();$c.ObservedOnRealReferent=$reader.ReadBoolean()
            $c.Applications=$reader.ReadInt64();$c.Successful=$reader.ReadInt64()
            $c.Failures=$reader.ReadInt64();$c.ElapsedTicks=$reader.ReadInt64()
            $deps=$reader.ReadInt32();$c.Dependencies=[string[]]@(for($j=0;$j -lt $deps;$j++){$reader.ReadString()})
            $field.Capabilities.Add($c.Key,$c)
            if($c.Depth -gt 1){$c.Kind='AcquiredComposition';$field.AcquiredCompositions++}
        }
        if($CapabilitiesOnly){
            # Keep the original archive intact. Rebind and reobserve live CLR evidence.
            foreach($cap in $field.Capabilities.Values){$cap.ObservedOnRealReferent=$false}
            return $field
        }
        $claims=$reader.ReadInt32()
        for($i=0;$i -lt $claims;$i++){
            $p=[ProvidencePercept]::new()
            $p.OwnerKey=$reader.ReadString();$p.ReferentKey=$reader.ReadString()
            $p.Key=$p.OwnerKey+' => '+$p.ReferentKey
            $p.Reliance=$reader.ReadString();$p.Acquired=$reader.ReadBoolean()
            $p.Version=$reader.ReadInt64();$p.Scope=$reader.ReadString()
            $evidence=$reader.ReadInt32()
            for($j=0;$j -lt $evidence;$j++){
                $b=[ProvidenceBearing]::new();$b.OwnerKey=$p.OwnerKey;$b.ReferentKey=$p.ReferentKey
                $b.CapabilityKey=$reader.ReadString();$b.SourceFamily=$reader.ReadString();$b.Valid=$reader.ReadBoolean()
                $p.Bearings.Add($b)
            }
            $field.Percepts[$p.Key]=$p
            foreach($key in @($p.OwnerKey,$p.ReferentKey)){
                if(!$field.PendingByKey.ContainsKey($key)){$field.PendingByKey[$key]=[List[ProvidencePercept]]::new()}
                $field.PendingByKey[$key].Add($p)
            }
        }
        $gaps=$reader.ReadInt32()
        for($i=0;$i -lt $gaps;$i++){
            $r=[ProvidenceReverie]::new()
            $r.Key=$reader.ReadString();$r.OwnerKey=$reader.ReadString();$r.MissingCapability=$reader.ReadString()
            $r.Reason=$reader.ReadString();$r.Status=$reader.ReadString();$r.Version=$reader.ReadInt64()
            $r.ResolutionCapability=$reader.ReadString()
            $typeName=$reader.ReadString()
            if($typeName){$r.NeededType=Resolve-ProvidenceType $typeName}
            $field.Reveries[$r.Key]=$r
        }
        $jobs=$reader.ReadInt32()
        for($i=0;$i -lt $jobs;$i++){
            $key=$reader.ReadString();$capKey=$reader.ReadString()
            if(!$field.PendingWorkByKey.ContainsKey($key)){$field.PendingWorkByKey[$key]=[List[string]]::new()}
            $field.PendingWorkByKey[$key].Add($capKey)
        }
        # Canonical CLR objects are never reconstructed from display names. Actual
        # source scans must rebind them; pending work resumes when their owners appear.
        return $field
    } finally {$reader.Dispose()}
}

Export-ModuleMember -Function New-ProvidenceField,Save-ProvidenceField,Import-ProvidenceField
