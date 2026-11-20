#requires -Version 7.5
param([int]$Runs = 3)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
Set-Location $root
. ./Invoke-HexagonDevelopment.ps1
. ./src/jobs/Kokoro.HmxConvRun.ps1
. ./src/kernels/Kokoro.HmxConv.ps1
$modes = @(
    'reference', 'input0', 'input1', 'input2', 'input3',
    'deep-2k', 'deep-4k', 'deep-8k', 'plain-2k', 'plain-4k', 'plain-8k',
    'single-wide', 'wrap-reference', 'wrap', 'wrap-linear'
)
$run = New-KokoroHmxConvRunSteps -Kernel 1 -Tiles $modes.Count -RunnerTelemetry
$l = $run.Layout
$steps = [Collections.Generic.List[hashtable]]::new()
$steps.AddRange([hashtable[]]$run.Steps)
$start = $steps.FindIndex({param($step) $step.Op -eq 'hwticks' -and $step.d -eq 26})
$end = $steps.FindIndex($start + 1, {param($step) $step.Op -eq 'hwticks'})
$steps.RemoveRange($start + 1, $end - $start - 1)
$p = [Collections.Generic.List[hashtable]]::new()
$imm = {
    param($r, $v)
    $p.Add(@{Op='lo';x=$r;i=($v -band 65535)})
    $p.Add(@{Op='hi';x=$r;i=($v -shr 16)})
}
$address = {
    param($r, $offset)
    & $imm $r $offset
    $p.Add(@{Op='add';d=$r;s=18;t=$r})
}
$pair = {
    param($activation, $weight, $ar, $wr, $actForm, $weightForm)
    & $address 6 ($l.ActivationOffset + $activation)
    & $address 10 ($l.WeightOffset + $weight)
    & $imm 7 $ar
    & $imm 8 $wr
    $p.Add(@{Op='hmx-pair';Act=$actForm;Wt=$weightForm;s=6;t=7;u=10;v=8})
}
$p.Add(@{Op='imm';d=9;i=0})
for ($i = 0; $i -lt $modes.Count; $i++) {
    $mode = $modes[$i]
    $p.Add(@{Op='mxclracc'})
    if ($mode -eq 'reference' -or $mode -like 'input*') {
        $panels = if ($mode -eq 'reference') {0..3} else {[int]$mode.Substring(5)}
        foreach ($panel in $panels) {
            & $pair (2048*$panel) (2048*$panel) 10239 2047 'act-ub-single' 'wt-b-deep'
        }
    } elseif ($mode -like 'wrap*') {
        # Ring tiles at 0 and 8192. The next physical panel at 16384 is poison.
        # Panel 12 packs the logical wrap. Panel 13 packs the physical continuation.
        $offset = @{ 'wrap-reference'=24576; 'wrap'=9216; 'wrap-linear'=26624 }[$mode]
        & $pair $offset 0 10239 2047 'act-ub-single' 'wt-b-deep'
    } elseif ($mode -eq 'single-wide') {
        & $pair 0 0 10239 8191 'act-ub-single' 'wt-b-deep'
    } else {
        $mode -match '^(deep|plain)-(\d)k$' | Out-Null
        $range = 1024 * [int]$Matches[2] - 1
        $weightForm = if ($Matches[1] -eq 'deep') {'wt-b-deep'} else {'wt-b'}
        & $pair 0 0 $range $range 'act-ub' $weightForm
    }
    for ($half = 0; $half -lt 2; $half++) {
        foreach ($plane in 0,1) {
            & $address 11 ($l.TableOffset + 256*$plane)
            & $address 12 ($l.OutputOffset + 8192*$i + 4096*$half + 2048*$plane)
            $p.Add(@{Op='bias-mxmem2';s=11})
            $op = if ($plane -eq 0) {'mxmem-after-retain-sat-ub'} else {'mxmem-after-ub'}
            $p.Add(@{Op=$op;s=12;t=9})
        }
    }
}
$p.Add(@{Op='load';d=14;s=12;Offset=2044})
$p.Add(@{Op='syncht'})
$steps.InsertRange($start + 1, $p)
$work = Join-Path $root 'build/residual-layout-20261120/operand-probe'
$emission = Join-Path $work 'emission'
$fixture = Join-Path $work 'fixture'
$null = New-Item -ItemType Directory -Force $emission,$fixture
$definition = @{
    Steps=$steps.ToArray()
    Symbol='kokoro_generator_tail_skel_handle_invoke'
    Soname='libkokoro_generator_tail_skel.so'
}
$null = Invoke-HexagonEmission -Kernel Definition -Definition $definition -OutputDirectory $emission
$a = [byte[]]::new($l.ActBytes)
for ($panel = 0; $panel -lt 12; $panel++) {
    for ($rowPair = 0; $rowPair -lt 16; $rowPair++) {
        for ($lane = 0; $lane -lt 128; $lane++) {
            $a[2048*$panel + 128*$rowPair + $lane] = 1 + 4*$panel + (($rowPair + $lane) % 4)
        }
    }
}
foreach ($entry in @(@(12,0), @(13,16384))) {
    [Array]::Copy($a, 9216, $a, 2048*$entry[0], 1024)
    [Array]::Copy($a, $entry[1], $a, 2048*$entry[0] + 1024, 1024)
}
$w = [byte[]]::new($l.WeightBytes)
for ($panel = 0; $panel -lt 4; $panel++) {
    # A different sparse weight in each 32-column half of every panel.
    for ($column = 0; $column -lt 64; $column++) {
        $w[2048*$panel + 1024*($column -shr 5) + 4*($column -band 31)] = 1 + $panel + 4*[int]($column -ge 32)
    }
}
$t = [byte[]]::new($l.TableBytes)
foreach ($plane in 0,1) {
    for ($column = 0; $column -lt 32; $column++) {
        $offset = 256*$plane + 4*$column
        $scale = if ($plane -eq 0) {0x4000} else {0x6000}
        [BitConverter]::GetBytes([int]$scale).CopyTo($t,$offset)
        [BitConverter]::GetBytes([int]32768).CopyTo($t,$offset+128)
    }
}
[IO.File]::WriteAllBytes((Join-Path $fixture 'activations.bin'),$a)
[IO.File]::WriteAllBytes((Join-Path $fixture 'weights.bin'),$w)
[IO.File]::WriteAllBytes((Join-Path $fixture 'tables.bin'),$t)
@{Tiles=$modes.Count;InputBytes=$l.ActBytes;OutputBytes=64+$l.OutputBytes;Samples=1;PcmOffset=64} |
    ConvertTo-Json | Set-Content (Join-Path $emission 'runner-layout.json')
$receipt = & ./tools/Invoke-GeneratorTailProbe.ps1 -EmissionDirectory $emission -FixtureDirectory $fixture -Soc SM8550 -Runs $Runs -TimeoutSeconds 65 -Adb 'C:/Dev/pwsh/scripts/adb.ps1'
$receipt | Set-Content (Join-Path $work 'phone.log')
$receipt | Write-Host
$output = $receipt | Where-Object {$_ -like 'OutputPath=*'} | Select-Object -Last 1
if (!$output -or ($receipt -join "`n") -notmatch '(?m)^Passed=True\s*$' -or ($receipt -join "`n") -notmatch '(?m)^StartupRestored=True\s*$') {
    throw 'The probe did not complete with a captured output and restored phone startup.'
}
$raw = [IO.File]::ReadAllBytes($output.Substring(11))
$report = for ($i = 0; $i -lt $modes.Count; $i++) {
    $offset = 64 + 8192*$i
    $record = [ordered]@{Mode=$modes[$i]}
    for ($half = 0; $half -lt 2; $half++) {
        $at = $offset + 4096*$half
        $ref = 64 + 4096*$half
        $different = 0
        for ($j = 0; $j -lt 4096; $j++) {
            if ($raw[$at+$j] -ne $raw[$ref+$j]) { $different++ }
        }
        $record["Half${half}Digest"] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw[$at..($at+4095)]))
        $record["Half${half}Diff"] = $different
        $record["Half${half}Sample"] = '{0:X2}{1:X2}' -f $raw[$at+1],$raw[$at+2049]
    }
    [pscustomobject]$record
}
# The retained and releasing stores recover the signed accumulator exactly for
# these small dot products. Check all 32 rows and all 64 output columns.
$window = {
    param($mode, $half, $lane)
    $at = 64 + 8192*[Array]::IndexOf($modes,$mode) + 4096*$half + 2*$lane + 1
    256*[int]$raw[$at] + [int]$raw[$at+2048] - 32768
}
foreach ($half in 0,1) {
    for ($lane = 0; $lane -lt 1024; $lane++) {
        $sum = 0
        foreach ($panel in 0..3) {
            $rowPair = $lane -shr 6
            $inputLane = 1 + 2*($lane -band 1)
            $expected = [int]$a[2048*$panel + 128*$rowPair + $inputLane] * (1 + $panel + 4*$half)
            if ((& $window "input$panel" $half $lane) -ne $expected) {
                throw "Single-panel scalar mismatch at panel $panel half $half lane $lane."
            }
            $sum += $expected
        }
        if ((& $window 'reference' $half $lane) -ne $sum) {
            throw "Four-panel scalar mismatch at half $half lane $lane."
        }
    }
}
$report | Export-Csv (Join-Path $work 'accumulator-windows.csv') -NoTypeInformation
$report | Format-Table Mode,Half0Diff,Half1Diff,Half0Sample,Half1Sample
