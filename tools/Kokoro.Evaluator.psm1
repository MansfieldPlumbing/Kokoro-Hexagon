#requires -Version 7.4
<#
.SYNOPSIS
Kokoro evaluator: runs a DSP job candidate on a phone, scores it against stock, logs it, and checks the ratchet.

.DESCRIPTION
One candidate = an emitter kernel with its parameters, run on an input (a capture-derived fixture directory). The
evaluator emits it (cached by a hash of the parameters and every file in src/hexagon, src/kernels and src/jobs), runs it on the attached phone of
the SoC (tools/Invoke-GeneratorTailProbe.ps1; unchanged staged files are not pushed again), scores PCM against the stock
PCM in the input (tools/Measure-KokoroPcmSnr.ps1), writes the WAV, and appends one row to build/evaluator/experiments.tsv.
Correctness gates timing: a candidate below its PCM floor is 'discard' whatever its speed.

The ratchet (tools/Kokoro.Ratchet.psd1, committed) lists cases with accepted values: PCM SNR floor, median DSP ms
ceiling, and the exact PCM hash where the path is bit-exact. Test-KokoroRatchet runs every case and prints one line for
the commit message. Only a measured improvement moves an accepted value (Update-KokoroRatchet), never a hand edit.

  Import-Module ./tools/Kokoro.Evaluator.psm1
  Test-KokoroRatchet                                   # every case; one line
  Invoke-KokoroExperiment -Case decoder-generator-hello-sm8550 -Parameters @{ ResidentBatchTiles = 16 }
  Invoke-KokoroSweep -Case decoder-generator-hello-sm8550 -Grid @{ ResidentHvxThreads = 2, 3, 4 }
#>

$script:Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Pwsh = (Get-Process -Id $PID).Path
$script:RatchetPath = Join-Path $PSScriptRoot 'Kokoro.Ratchet.psd1'
$script:LogPath = Join-Path $script:Root 'build/evaluator/experiments.tsv'
$script:Standards = @{
    Pass = 'Ratchet: put the score line in the commit message; Update-KokoroRatchet moves an accepted value only after a measured gain.'
    Fail = 'Make this failure impossible to repeat: a check, a clearer error or a tool fix, not a handoff note.'
}

function Get-KokoroSourceKey {
    $files = @(foreach ($d in 'hexagon', 'kernels', 'jobs') { Get-ChildItem (Join-Path $script:Root "src/$d") -Filter '*.ps1' -File }) + @(Get-Item (Join-Path $script:Root 'tools/Emit-HexagonProbe.ps1'))
    $lines = foreach ($f in ($files | Sort-Object FullName)) { "$($f.Name)=$((Get-FileHash -LiteralPath $f.FullName).Hash)" }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))
}

function Get-KokoroRatchetCase {
    <# .SYNOPSIS The ratchet's cases (all, or one by name). #>
    param([string]$Name)
    $cases = (Import-PowerShellDataFile $script:RatchetPath).Cases
    if ($Name) { $c = $cases | Where-Object Name -eq $Name; if (-not $c) { throw "No ratchet case '$Name' in $script:RatchetPath." }; if ($c.Blocked) { throw "Case '$Name' is blocked: $($c.Blocked)" }; return $c }
    $cases
}

function Invoke-KokoroEmission {
    <# .SYNOPSIS Emits one job (Emit-HexagonProbe.ps1 -Kernel with -Parameters) or returns the cached emission. #>
    param([Parameter(Mandatory)][string]$Kernel, [hashtable]$Parameters = @{}, [string]$SourceKey = (Get-KokoroSourceKey))
    $pairs = foreach ($k in ($Parameters.Keys | Sort-Object)) { "$k=$($Parameters[$k])" }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Kernel`n$($pairs -join "`n")`n$SourceKey"))).Substring(0, 16)
    $dir = Join-Path $script:Root "build/evaluator/emit/$Kernel-$key"
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'runner-layout.json'))) {
        $arguments = @('-NoProfile', '-File', (Join-Path $script:Root 'tools/Emit-HexagonProbe.ps1'), '-Kernel', $Kernel, '-OutputDirectory', $dir, '-Force')
        foreach ($k in ($Parameters.Keys | Sort-Object)) { $v = $Parameters[$k]; if ($v -is [bool]) { if ($v) { $arguments += "-$k" } } else { $arguments += "-$k", "$v" } }
        $out = & $script:Pwsh @arguments 2>&1
        if ($LASTEXITCODE -or -not (Test-Path -LiteralPath (Join-Path $dir 'runner-layout.json'))) {
            # The emitter's own message (a thrown layout or encoding error) is the cause; the rest is stack text.
            $cause = @($out | ForEach-Object { "$_" } | Where-Object { $_.Trim().StartsWith('|') -and -not $_.Trim().TrimStart('|').Trim().StartsWith('~') }) | Select-Object -Last 1; if ($cause) { $cause = $cause.Trim().TrimStart('|').Trim() }
            if (-not $cause) { $cause = ($out | Select-Object -Last 1) }
            throw "emission refused ($($pairs -join ' ')): $cause" }
    }
    [pscustomobject]@{ Kernel = $Kernel; Key = $key; Directory = $dir; LibrarySHA256 = (Get-FileHash -LiteralPath (Join-Path $dir 'libkokoro_generator_tail_skel.so')).Hash }
}

function Test-KokoroKernel {
    <#
    .SYNOPSIS Emits kernels (any tools/Emit-HexagonProbe.ps1 -Kernel, with -Parameters) and checks their instruction bytes
    against the SDK assembler (tools/Test-HexagonEmission.ps1). One line per kernel; cached by kernel, parameters and the
    emitter sources. This is the cheap first check for a new or changed kernel, before the simulator or a phone.
    #>
    param([Parameter(Mandatory)][string[]]$Kernel, [hashtable]$Parameters = @{})
    $sourceKey = Get-KokoroSourceKey
    foreach ($k in @($Kernel | ForEach-Object { $_.Split(',') } | Where-Object { $_ })) {
        $pairs = foreach ($n in ($Parameters.Keys | Sort-Object)) { "$n=$($Parameters[$n])" }
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$k`n$($pairs -join "`n")`n$sourceKey"))).Substring(0, 16)
        $dir = Join-Path $script:Root "build/evaluator/kernel/$k-$key"
        $row = [ordered]@{ Kernel = $k; Parameters = ($pairs -join ' '); CodeBytes = $null; AssemblerMatch = $false; Reason = '' }
        try {
            # Test-HexagonEmission.ps1 writes its verdict to <dir>/<kernel>/check-<guid>/verification.json.
            if (-not (Test-Path -LiteralPath $dir) -or -not (Get-ChildItem -LiteralPath $dir -Recurse -Filter 'verification.json' | Select-Object -First 1)) {
                $arguments = @('-NoProfile', '-File', (Join-Path $script:Root 'tools/Test-HexagonEmission.ps1'), '-Kernel', $k, '-OutputDirectory', $dir, '-Force')
                foreach ($n in ($Parameters.Keys | Sort-Object)) { $v = $Parameters[$n]; if ($v -is [bool]) { if ($v) { $arguments += "-$n" } } else { $arguments += "-$n", "$v" } }
                $out = & $script:Pwsh @arguments 2>&1
                if ($LASTEXITCODE) { throw (($out | Select-Object -Last 3) -join ' | ') }
            }
            $v = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'verification.json' | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
            $row.CodeBytes = $v.CodeBytes; $row.AssemblerMatch = [bool]$v.InstructionBytesMatch
        } catch { $row.Reason = "$_" }
        Write-Host ('{0,-6} {1,-36} {2,7} bytes {3}' -f $(if ($row.AssemblerMatch) { 'PASS' } else { 'FAIL' }), $k, $row.CodeBytes, $row.Reason) -ForegroundColor $(if ($row.AssemblerMatch) { 'Green' } else { 'Yellow' })
        if (-not $row.AssemblerMatch) { Write-Host "  ! $($script:Standards.Fail)" -ForegroundColor DarkYellow }
        [pscustomobject]$row
    }
}

function Invoke-KokoroExperiment {
    <#
    .SYNOPSIS Runs one candidate of a ratchet case (the case's parameters, overridden by -Parameters) on the phone and
    scores it. Prints one line; returns the full result. Status: keep (meets every accepted value and improves one),
    hold (meets them, no gain beyond noise), discard (misses one), crash (did not produce output).
    #>
    param([Parameter(Mandatory)][string]$Case, [hashtable]$Parameters = @{}, [string]$Setup, [string]$Hypothesis = '', [ValidateRange(1, 20)][int]$Runs = 3)
    $c = Get-KokoroRatchetCase $Case
    if ($Setup) {
        $s = (Import-PowerShellDataFile $script:RatchetPath).Setups[$Setup]; if ($null -eq $s) { throw "No setup '$Setup' in $script:RatchetPath." }
        $merged = @{}; foreach ($k in $s.Keys) { $merged[$k] = $s[$k] }; foreach ($k in $Parameters.Keys) { $merged[$k] = $Parameters[$k] }; $Parameters = $merged
        if (-not $Hypothesis) { $Hypothesis = "setup $Setup" }
    }
    $p = @{}; foreach ($k in $c.Parameters.Keys) { $p[$k] = $c.Parameters[$k] }; foreach ($k in $Parameters.Keys) { $p[$k] = $Parameters[$k] }
    $label = ($p.Keys | Sort-Object | ForEach-Object { "$_=$($p[$_])" }) -join ' '
    $r = [ordered]@{ Case = $c.Name; Setup = $label; Status = 'crash'; MedianMs = $null; PcmSnrDb = $null; Clipped = $null; PcmSHA256 = $null; Wav = $null; Reason = '' }
    try {
        $e = Invoke-KokoroEmission -Kernel $c.Kernel -Parameters $p
        $inputDir = Join-Path $script:Root $c.Input
        $out = & $script:Pwsh -NoProfile -File (Join-Path $script:Root 'tools/Invoke-GeneratorTailProbe.ps1') -EmissionDirectory $e.Directory -FixtureDirectory $inputDir -Soc $c.Soc -Runs $Runs -TimeoutSeconds 300 2>&1
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        $field = { param([string]$n) $i = $text.IndexOf("$n="); if ($i -lt 0) { return $null }; $j = $i + $n.Length + 1; $k = $j; while ($k -lt $text.Length -and -not [char]::IsWhiteSpace($text[$k])) { $k++ }; $text.Substring($j, $k - $j) }
        $outputPath = & $field 'OutputPath'
        if (-not $outputPath) { $r.Reason = "no output: $(($out | Select-Object -Last 3) -join ' | ')"; throw 'no output' }
        $r.MedianMs = [double](& $field 'MedianRegionMs')
        $wavDir = Join-Path $script:Root 'build/evaluator/wav'; $null = New-Item -ItemType Directory -Force $wavDir
        $r.Wav = Join-Path $wavDir ("{0}-{1}-{2:yyyyMMdd-HHmmss}.wav" -f $c.Name, $e.Key, (Get-Date))
        $pcmOffset = [int](Get-Content -LiteralPath (Join-Path $e.Directory 'runner-layout.json') -Raw | ConvertFrom-Json).PcmOffset
        $m = & (Join-Path $script:Root 'tools/Measure-KokoroPcmSnr.ps1') -OutputPath $outputPath -FixtureDirectory $inputDir -PcmOffset $pcmOffset -WavPath $r.Wav
        $r.PcmSnrDb = $m.PcmSnrDb; $r.Clipped = $m.ClippedSamples; $r.PcmSHA256 = $m.PcmSHA256
        $misses = @()
        if ($r.PcmSnrDb -lt $c.PcmSnrDbFloor) { $misses += "PCM $($r.PcmSnrDb) dB < floor $($c.PcmSnrDbFloor)" }
        if ($c.ClippedCeiling -ne $null -and $r.Clipped -gt $c.ClippedCeiling) { $misses += "clipped $($r.Clipped) > $($c.ClippedCeiling)" }
        if ($c.PcmSHA256 -and -not $Parameters.Count -and $r.PcmSHA256 -ne $c.PcmSHA256) { $misses += "PCM hash $($r.PcmSHA256.Substring(0, 8)) != accepted $($c.PcmSHA256.Substring(0, 8))" }
        if ($r.MedianMs -gt $c.MedianMsCeiling * (1 + $c.NoiseFraction)) { $misses += "median $($r.MedianMs) ms > ceiling $($c.MedianMsCeiling) (+$([int](100 * $c.NoiseFraction))% noise)" }
        $gain = ($r.MedianMs -lt $c.MedianMsCeiling * (1 - $c.NoiseFraction)) -or ($r.PcmSnrDb -gt $c.PcmSnrDbFloor + 0.1)
        $r.Status = if ($misses) { 'discard' } elseif ($gain) { 'keep' } else { 'hold' }
        $r.Reason = $misses -join '; '
    } catch { if (-not $r.Reason) { $r.Reason = "$_" } }
    $null = New-Item -ItemType Directory -Force (Split-Path $script:LogPath)
    if (-not (Test-Path $script:LogPath)) { [IO.File]::WriteAllText($script:LogPath, "time`tcommit`tcase`tsetup`tstatus`tmedian_ms`tpcm_db`tclipped`tpcm_sha256`treason`thypothesis`n") }
    $commit = (git -C $script:Root rev-parse --short HEAD 2>$null) + $(if (git -C $script:Root status --porcelain 2>$null) { '+' } else { '' })
    [IO.File]::AppendAllText($script:LogPath, ((@((Get-Date).ToString('s'), $commit, $r.Case, $r.Setup, $r.Status, $r.MedianMs, $r.PcmSnrDb, $r.Clipped, $r.PcmSHA256, $r.Reason, $Hypothesis) -join "`t") + "`n"))
    $color = @{ keep = 'Green'; hold = 'Gray'; discard = 'Yellow'; crash = 'Red' }[$r.Status]
    Write-Host ("{0,-8} {1}  [{2}]  {3} ms  {4} dB  clip {5}  pcm {6}  {7}" -f $r.Status.ToUpper(), $c.Name, $label, $r.MedianMs, $r.PcmSnrDb, $r.Clipped, $(if ($r.PcmSHA256) { $r.PcmSHA256.Substring(0, 8) }), $r.Reason) -ForegroundColor $color
    if ($r.Status -in 'discard', 'crash') { Write-Host "  ! $($script:Standards.Fail)" -ForegroundColor DarkYellow } elseif ($r.Status -eq 'keep') { Write-Host "  ! $($script:Standards.Pass)" -ForegroundColor DarkYellow }
    [pscustomobject]$r
}

function Invoke-KokoroSweep {
    <# .SYNOPSIS Every combination of -Grid values as experiments on one case; the experiment log keeps every row. #>
    param([Parameter(Mandatory)][string]$Case, [Parameter(Mandatory)][hashtable]$Grid, [string]$Hypothesis = '', [int]$Runs = 3)
    $combos = @(@{})
    foreach ($k in ($Grid.Keys | Sort-Object)) { $combos = @(foreach ($c in $combos) { foreach ($v in @($Grid[$k])) { $n = $c.Clone(); $n[$k] = $v; $n } }) }
    foreach ($c in $combos) { Invoke-KokoroExperiment -Case $Case -Parameters $c -Hypothesis $Hypothesis -Runs $Runs }
}

function Compare-KokoroSetup {
    <#
    .SYNOPSIS Runs named setups (tools/Kokoro.Ratchet.psd1 Setups) on one case and prints them fastest first, with
    the change against Baseline. Every run is also an experiment-log row.
    #>
    param([Parameter(Mandatory)][string]$Case, [string[]]$Setup = @('Baseline'), [int]$Runs = 3)
    $names = @($Setup | ForEach-Object { $_.Split(',') } | Where-Object { $_ }); if ('Baseline' -notin $names) { $names = @('Baseline') + $names }
    $rows = foreach ($n in $names) { $r = Invoke-KokoroExperiment -Case $Case -Setup $n -Runs $Runs 6>$null; [pscustomobject]@{ Setup = $n; Status = $r.Status; MedianMs = $r.MedianMs; PcmSnrDb = $r.PcmSnrDb; Clipped = $r.Clipped; Pcm = $(if ($r.PcmSHA256) { $r.PcmSHA256.Substring(0, 8) }); Reason = $r.Reason } }
    $base = ($rows | Where-Object Setup -eq 'Baseline').MedianMs
    foreach ($r in ($rows | Sort-Object { if ($null -eq $_.MedianMs) { [double]::MaxValue } else { $_.MedianMs } })) {
        $noise = (Get-KokoroRatchetCase $Case).NoiseFraction
        $delta = if ($base -and $r.MedianMs) { $d = ($r.MedianMs - $base) / $base; '{0:+0.0;-0.0}%{1}' -f (100 * $d), $(if ([math]::Abs($d) -lt $noise -and $r.Setup -ne 'Baseline') { ' (noise)' } else { '' }) } else { '' }
        Write-Host ('{0,-10} {1,-8} {2,9} ms {3,7}  {4,6} dB  clip {5}  pcm {6}  {7}' -f $r.Setup, $r.Status, $r.MedianMs, $delta, $r.PcmSnrDb, $r.Clipped, $r.Pcm, $r.Reason)
    }
    $rows
}

function Test-KokoroRatchet {
    <# .SYNOPSIS Runs every ratchet case (or -Case) with its accepted setup and prints one line for the commit message. #>
    param([string[]]$Case, [int]$Runs = 3)
    $cases = Get-KokoroRatchetCase | Where-Object { -not $Case -or $_.Name -in $Case }
    $blocked = @($cases | Where-Object { $_.Blocked })
    foreach ($c in $blocked) { Write-Host ("BLOCKED  {0}  ({1})  {2}" -f $c.Name, $c.Audio, $c.Blocked) -ForegroundColor DarkGray }
    $results = @(foreach ($c in ($cases | Where-Object { -not $_.Blocked })) { Invoke-KokoroExperiment -Case $c.Name -Runs $Runs })
    $bad = @($results | Where-Object Status -in 'discard', 'crash'); $better = @($results | Where-Object Status -eq 'keep')
    $line = "ratchet: {0} run, {1} regressions, {2} improved, {3} blocked" -f $results.Count, $bad.Count, $better.Count, $blocked.Count
    Write-Host $line -ForegroundColor $(if ($bad.Count) { 'Yellow' } else { 'Green' })
}

function Update-KokoroRatchet {
    <#
    .SYNOPSIS Moves one case's accepted values to a measured experiment result (a 'keep' row), in the committed ratchet
    file: the median becomes the new ceiling, the SNR the new floor (never lowered), the PCM hash the accepted hash.
    #>
    param([Parameter(Mandatory)]$Result, [hashtable]$Parameters)
    if ($Result.Status -ne 'keep') { throw "Only a 'keep' result moves the ratchet (this one is '$($Result.Status)')." }
    $text = [IO.File]::ReadAllText($script:RatchetPath)
    $c = Get-KokoroRatchetCase $Result.Case
    $text = $text.Replace("MedianMsCeiling = $($c.MedianMsCeiling)", "MedianMsCeiling = $($Result.MedianMs)")
    if ($Result.PcmSnrDb -gt $c.PcmSnrDbFloor) { $text = $text.Replace("PcmSnrDbFloor = $($c.PcmSnrDbFloor)", "PcmSnrDbFloor = $($Result.PcmSnrDb)") }
    if ($c.PcmSHA256) { $text = $text.Replace("PcmSHA256 = '$($c.PcmSHA256)'", "PcmSHA256 = '$($Result.PcmSHA256)'") }
    [IO.File]::WriteAllText($script:RatchetPath, $text)
    Write-Host "Ratchet moved for $($c.Name); commit tools/Kokoro.Ratchet.psd1 with the change and its score line." -ForegroundColor Green
}

Export-ModuleMember -Function Get-KokoroSourceKey, Get-KokoroRatchetCase, Invoke-KokoroEmission, Test-KokoroKernel, Invoke-KokoroExperiment, Invoke-KokoroSweep, Compare-KokoroSetup, Test-KokoroRatchet, Update-KokoroRatchet
