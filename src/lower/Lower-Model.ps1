#requires -Version 7.4
# Lower a model written as ordinary PowerShell into a tensor operation DAG.
#
# The description is PowerShell source. SMA parses it; this walks the AST and recovers the
# graph. PowerShell is the authoring language, not the runtime: nothing here executes the
# model, it only decides what the graph is. A backend then emits QNN ops, HVX code or a CPU
# delegate from the same DAG, and chooses what fuses.
#
# The AST rather than SMA's lowered expression tree, deliberately: the expression tree is
# full of dynamic binder call-sites and PSObject boxing, which is PowerShell's own semantics
# and noise for this purpose. The AST is the structure before that lands.
[CmdletBinding()]
param([Parameter(Mandatory)][scriptblock] $Model)
$ErrorActionPreference = 'Stop'

$ast = $Model.Ast
$nodes = [Collections.Generic.List[object]]::new()
$emitBody = {
    param($cmd, [string]$name)
    $opName = $cmd.GetCommandName()
    $operands = [Collections.Generic.List[string]]::new()
    $attrs = [Collections.Specialized.OrderedDictionary]::new()
    for ([int]$ei = 1; $ei -lt $cmd.CommandElements.Count; $ei++) {
        $el = $cmd.CommandElements[$ei]
        if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
            $val = if ($el.Argument) { $el.Argument.Extent.Text }
                   elseif ($ei + 1 -lt $cmd.CommandElements.Count) { $cmd.CommandElements[++$ei].Extent.Text }
                   else { $true }
            $attrs[$el.ParameterName] = $val
            continue
        }
        $operands.Add((& $operand $el))
    }
    [int]$id = $nodes.Count
    $nodes.Add([pscustomobject]@{
        Id = $id; Result = $(if ($name) { $name } else { "t$id" }); Op = $opName
        Inputs = $operands.ToArray(); Attrs = $attrs
        Line = $cmd.Extent.StartLineNumber
    })
    if ($name) { $defs[$name] = $id }
    $id
}
$defs = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)

# Operand: either a previously defined value, or a free input.
# Nested calls are hoisted into their own nodes, so (Mul (Abs $d) $m) becomes two nodes and
# the outer one references the inner by id. Anonymous - it never had a variable name.
$emit = $emitBody
$operand = {
    param($expr)
    if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $expr.VariablePath.UserPath
        if ($defs.ContainsKey($name)) { return "%$($defs[$name])" }
        return "@$name"
    }
    if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) { return "#$($expr.Value)" }
    if ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $inner = $expr.Pipeline.PipelineElements[0]
        if ($inner -is [System.Management.Automation.Language.CommandAst]) { return '%' + (& $emit $inner $null) }
        return & $operand $inner.Expression
    }
    return "?$($expr.Extent.Text)"
}

# Each assignment whose right-hand side is a command becomes one node.
foreach ($stmt in $ast.EndBlock.Statements) {
    if ($stmt -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
    $target = $stmt.Left.VariablePath.UserPath
    $rhs = $stmt.Right
    if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { continue }
    $cmd = $rhs.PipelineElements[0]
    if ($cmd -isnot [System.Management.Automation.Language.CommandAst]) { continue }

    [void](& $emit $cmd $target)
}

# Common subexpression elimination: identical op over identical operands with identical
# attributes is computed once. On full-size tensors each removal is a whole pass over memory.
$key = { param($n) ($n.Op + '|' + ($n.Inputs -join ',') + '|' + (($n.Attrs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')) }
$seen = @{}; $remap = @{}
$kept = [Collections.Generic.List[object]]::new()
foreach ($n in $nodes) {
    $n.Inputs = @($n.Inputs | ForEach-Object { if ($_ -like '%*' -and $remap.ContainsKey([int]$_.Substring(1))) { '%' + $remap[[int]$_.Substring(1)] } else { $_ } })
    $sig = & $key $n
    if ($seen.ContainsKey($sig)) { $remap[$n.Id] = $seen[$sig]; continue }
    $seen[$sig] = $n.Id
    $kept.Add($n)
}
$nodes = $kept

# Consumers, so a backend can see where a value dies - which is what decides whether an
# intermediate ever has to reach memory.
$uses = @{}
foreach ($n in $nodes) { foreach ($inp in $n.Inputs) { if ($inp -like '%*') { $src = [int]$inp.Substring(1); $uses[$src] = 1 + [int]$uses[$src] } } }
foreach ($n in $nodes) { $n | Add-Member -NotePropertyName Consumers -NotePropertyValue ([int]$uses[$n.Id]) -Force }

$nodes
