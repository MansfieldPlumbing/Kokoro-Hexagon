#requires -Version 7.4
# Exhaustive Phase 1 Verification of Pure PowerShell Named Encoders for Hexagon V73 HMX and Pcycle.
# Tests systematic sweeps of legal register operands, boundaries, modifiers, and invalid operand rejections.
# Compares bit-for-bit against the pinned Qualcomm Hexagon SDK LLVM assembler oracle.

[CmdletBinding()]
param(
    [string] $ToolRoot = '/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/bin',
    [string] $ProtoPath = '/home/scott/hexagon/Hexagon_SDK/6.4.0.2/tools/HEXAGON_Tools/19.0.04/Tools/target/hexagon/include/hmx_hexagon_protos.h'
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\emit\Hexagon.ps1')

Write-Host "================================================================="
Write-Host " Phase 1: Named HMX & Pcycle Encoder Exhaustive Validation Suite "
Write-Host "================================================================="

# 1. Oracle Verification & Pinning
$assembler = "$ToolRoot/hexagon-llvm-mc"
$asmHash = (& wsl.exe --exec sha256sum $assembler 2>$null | Select-Object -Last 1) -split '\s+'
if ($asmHash[0] -ne 'fc64c65aca06186106a73ba93e65ddf7c906bf4905b786dc748d3f034401ea27') {
    throw "Assembler hash mismatch: $($asmHash[0])"
}
$protoHash = (& wsl.exe --exec sha256sum $ProtoPath 2>$null | Select-Object -Last 1) -split '\s+'
if ($protoHash[0] -ne 'b902a75377335f9e89b0ea01c3e3d4836fdebde0703d5a82328dde26af17808e') {
    throw "HMX proto header hash mismatch: $($protoHash[0])"
}

Write-Host "[+] Pinned Assembler: $assembler (SHA-256: $($asmHash[0]))"
Write-Host "[+] Pinned HMX Protos: $ProtoPath (SHA-256: $($protoHash[0]))"

$testCases = [Collections.Generic.List[hashtable]]::new()

# A. Pcycle Register Pair Sweeps (All 16 legal register pairs: r1:0, r3:2, ..., r31:30)
for ($r = 0; $r -le 30; $r += 2) {
    $testCases.Add(@{
        Category = "Pcycle"
        Step     = @{ Op='pcycle'; d=$r }
        Expected = "r$($r+1):$($r) = pcycle"
    })
}

# B. Store-D Immediate Offset & Register Sweeps
$storeOffsets = @(0, 8, 16, 24, 32, 64, 128, 512, 1024, 2048, 4088, -8, -16, -32, -64, -512, -4096)
$storeRegs = @(0, 2, 4, 14, 28, 30)
foreach ($off in $storeOffsets) {
    foreach ($r in $storeRegs) {
        $testCases.Add(@{
            Category = "Store-D"
            Step     = @{ Op='store-d'; s=14; t=$r; Offset=$off }
            Expected = "memd(r14+#$off) = r$($r+1):$($r)"
        })
    }
}

# C. Mxclracc and Mxclracc.hf
$testCases.Add(@{ Category="Control"; Step=@{ Op='mxclracc' }; Expected="mxclracc" })
$testCases.Add(@{ Category="Control"; Step=@{ Op='mxclracc.hf' }; Expected="mxclracc.hf" })

# D. Cvt Operations across all 32 source registers
for ($r = 0; $r -le 31; $r++) {
    $testCases.Add(@{ Category="Cvt-HF"; Step=@{ Op='cvt-hf'; s=$r }; Expected="cvt.hf = acc(r$r)" })
    $testCases.Add(@{ Category="Cvt-UB"; Step=@{ Op='cvt-ub'; s=$r }; Expected="cvt.ub = acc(r$r)" })
    $testCases.Add(@{ Category="Cvt-UB-SC0"; Step=@{ Op='cvt-ub-sc0'; s=$r }; Expected="cvt.ub = acc(r$r):sc0" })
    $testCases.Add(@{ Category="Cvt-UB-SC1"; Step=@{ Op='cvt-ub-sc1'; s=$r }; Expected="cvt.ub = acc(r$r):sc1" })
}

# E. Mxmem-Cvt across register boundaries
$boundRegs = @(0, 1, 4, 7, 10, 15, 16, 28, 30, 31)
foreach ($s in $boundRegs) {
    foreach ($t in $boundRegs) {
        $testCases.Add(@{
            Category = "Mxmem-Cvt"
            Step     = @{ Op='mxmem-cvt'; s=$s; t=$t }
            Expected = "mxmem(r$s,r$t) = cvt"
        })
    }
}

# F. Integer accumulator extraction and HVX byte-plane shuffle.
foreach ($s in $boundRegs) {
    $testCases.Add(@{ Category="Bias-Mxmem"; Step=@{ Op='bias-mxmem'; s=$s }; Expected="bias = mxmem(r$s)" })
}
foreach ($s in $boundRegs) {
    foreach ($t in $boundRegs) {
        $testCases.Add(@{
            Category="Mxmem-Int32-Plane"
            Step=@{ Op='mxmem-after-retain-cm-ub'; s=$s; t=$t }
            Expected="mxmem(r$s,r$t):after:retain:cm.ub = acc"
        })
    }
}
foreach ($case in @(
    @(0,0,0,0), @(2,2,0,7), @(30,4,1,7), @(4,30,2,1), @(6,31,3,1)
)) {
    $d=$case[0]; $s=$case[1]; $t=$case[2]; $r=$case[3]
    $testCases.Add(@{
        Category="HVX-Vshuff"
        Step=@{ Op='vshuff'; d=$d; s=$s; t=$t; r=$r }
        Expected="v$($d+1):$d = vshuff(v$s,v$t,r$r)"
    })
}

# G. Paired HMX Packets (FP16, W8A8, W4A8) across register boundaries
foreach ($s in @(0, 4, 10, 15, 28, 31)) {
    foreach ($t in @(1, 5, 11, 16, 29)) {
        foreach ($u in @(2, 6, 12, 20, 30)) {
            foreach ($v in @(3, 7, 13, 21, 31)) {
                $testCases.Add(@{
                    Category = "HMX-FP16"
                    Step     = @{ Op='mxmpy-fp16'; s=$s; t=$t; u=$u; v=$v }
                    Expected = "{`n`tactivation.hf = mxmem(r$s,r$t)`n`tweight.hf = mxmem(r$u,r$v)`n}"
                })
                $testCases.Add(@{
                    Category = "HMX-W8A8"
                    Step     = @{ Op='mxmpy-w8a8'; s=$s; t=$t; u=$u; v=$v }
                    Expected = "{`n`tactivation.ub = mxmem(r$s,r$t)`n`tweight.b = mxmem(r$u,r$v)`n}"
                })
                $testCases.Add(@{
                    Category = "HMX-W4A8"
                    Step     = @{ Op='mxmpy-w4a8'; s=$s; t=$t; u=$u; v=$v }
                    Expected = "{`n`tactivation.ub = mxmem(r$s,r$t)`n`tweight.n = mxmem(r$u,r$v)`n}"
                })
            }
        }
    }
}

Write-Host "[+] Generated $($testCases.Count) legal assembly test cases across all categories."

# Assemble all test cases in batch via hexagon-llvm-mc
$asmLines = [Collections.Generic.List[string]]::new()
$asmLines.Add('.text')
$asmLines.Add('.p2align 2')
$asmLines.Add('.global test_suite')
$asmLines.Add('test_suite:')

$isa = Get-InstructionSet
$pwshBytesList = [Collections.Generic.List[byte]]::new()

foreach ($tc in $testCases) {
    $asmText = ConvertTo-HexagonAssembly $tc.Step
    $asmLines.Add($asmText)
    $bytes = [byte[]](New-HexagonInstruction $tc.Step 0 0)
    $pwshBytesList.AddRange($bytes)
}

$tempDir = Join-Path $env:TEMP ('hmx_oracle_' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempDir)
$asmFile = Join-Path $tempDir 'suite.s'
$objFile = Join-Path $tempDir 'suite.o'
[IO.File]::WriteAllText($asmFile, ($asmLines -join "`n") + "`n")

$wslAsm = (& wsl.exe --exec wslpath -a $asmFile 2>$null | Select-Object -Last 1).Trim()
$wslObj = (& wsl.exe --exec wslpath -a $objFile 2>$null | Select-Object -Last 1).Trim()

& wsl.exe --exec $assembler -triple=hexagon -mcpu=hexagonv73 "-mattr=+hvxv73,+hvx-length128b,+hvx-ieee-fp,+hmxv73" -filetype=obj $wslAsm -o $wslObj 2>$null
if ($LASTEXITCODE -ne 0) { throw "Batch oracle assembly failed" }

# Extract oracle .text bytes from ELF
$objBytes = [IO.File]::ReadAllBytes($objFile)
$sectionOffset = [BitConverter]::ToUInt32($objBytes, 32)
$sectionSize   = [BitConverter]::ToUInt16($objBytes, 46)
$sectionCount  = [BitConverter]::ToUInt16($objBytes, 48)
$namesIndex    = [BitConverter]::ToUInt16($objBytes, 50)
$nameSection   = [long]$sectionOffset + $namesIndex * $sectionSize
$namesOffset   = [BitConverter]::ToUInt32($objBytes, $nameSection + 16)
$namesSize     = [BitConverter]::ToUInt32($objBytes, $nameSection + 20)

$oracleBytes = $null
for ($i = 0; $i -lt $sectionCount; $i++) {
    $at = [long]$sectionOffset + $i * $sectionSize
    $nameAt = [long]$namesOffset + [BitConverter]::ToUInt32($objBytes, $at)
    $end = $nameAt
    while ($end -lt ($namesOffset + $namesSize) -and $objBytes[$end] -ne 0) { $end++ }
    $sName = [Text.Encoding]::ASCII.GetString($objBytes, $nameAt, $end - $nameAt)
    if ($sName -eq '.text') {
        $off = [BitConverter]::ToUInt32($objBytes, $at + 16)
        $sz  = [BitConverter]::ToUInt32($objBytes, $at + 20)
        $oracleBytes = [byte[]]::new($sz)
        [Array]::Copy($objBytes, $off, $oracleBytes, 0, $sz)
        break
    }
}

if ($null -eq $oracleBytes) { throw "Failed to extract .text section from oracle object" }

$pwshBytes = $pwshBytesList.ToArray()
if ($pwshBytes.Length -ne $oracleBytes.Length) {
    throw "Length mismatch: PowerShell emitted $($pwshBytes.Length) bytes, Oracle has $($oracleBytes.Length) bytes"
}

$mismatchCount = 0
for ($i = 0; $i -lt $pwshBytes.Length; $i++) {
    if ($pwshBytes[$i] -ne $oracleBytes[$i]) {
        $mismatchCount++
    }
}

Write-Host "[+] Total Tested Instructions/Packets: $($testCases.Count)"
Write-Host "[+] Total Emitted Code Bytes: $($pwshBytes.Length)"
Write-Host "[+] Oracle Byte Mismatches: $mismatchCount"

if ($mismatchCount -ne 0) {
    throw "Exhaustive legal validation FAILED with $mismatchCount byte mismatches"
}
Write-Host "[+] Legal Instruction Sweep: 100% BIT-EXACT MATCH WITH LLVM ORACLE" -ForegroundColor Green

# 2. Intentionally Invalid Rejections Sweep
$invalidCases = @(
    @{ Name="Pcycle odd reg 1"; Step=@{ Op='pcycle'; d=1 } },
    @{ Name="Pcycle odd reg 31"; Step=@{ Op='pcycle'; d=31 } },
    @{ Name="Pcycle out of range 32"; Step=@{ Op='pcycle'; d=32 } },
    @{ Name="Store-D odd reg 1"; Step=@{ Op='store-d'; s=14; t=1; Offset=0 } },
    @{ Name="Store-D unaligned offset 4"; Step=@{ Op='store-d'; s=14; t=0; Offset=4 } },
    @{ Name="Store-D unaligned offset 7"; Step=@{ Op='store-d'; s=14; t=0; Offset=7 } },
    @{ Name="Store-D out of range offset 16384"; Step=@{ Op='store-d'; s=14; t=0; Offset=16384 } },
    @{ Name="Cvt-HF out of range 32"; Step=@{ Op='cvt-hf'; s=32 } },
    @{ Name="Cvt-UB out of range 32"; Step=@{ Op='cvt-ub'; s=32 } },
    @{ Name="Mxmem-Cvt out of range base 32"; Step=@{ Op='mxmem-cvt'; s=32; t=0 } },
    @{ Name="Mxmem-Cvt out of range stride 32"; Step=@{ Op='mxmem-cvt'; s=0; t=32 } },
    @{ Name="Bias-Mxmem out of range 32"; Step=@{ Op='bias-mxmem'; s=32 } },
    @{ Name="Integer plane store out of range stride 32"; Step=@{ Op='mxmem-after-retain-cm-ub'; s=0; t=32 } },
    @{ Name="Vshuff odd destination"; Step=@{ Op='vshuff'; d=1; s=0; t=0; r=0 } },
    @{ Name="Vshuff scalar register 8"; Step=@{ Op='vshuff'; d=0; s=0; t=0; r=8 } },
    @{ Name="HMX-FP16 out of range s 32"; Step=@{ Op='mxmpy-fp16'; s=32; t=0; u=0; v=0 } },
    @{ Name="HMX-W8A8 out of range u 32"; Step=@{ Op='mxmpy-w8a8'; s=0; t=0; u=32; v=0 } },
    @{ Name="HMX-W4A8 out of range v 32"; Step=@{ Op='mxmpy-w4a8'; s=0; t=0; u=0; v=32 } }
)

$rejectedCount = 0
foreach ($inv in $invalidCases) {
    $threw = $false
    try {
        $null = New-HexagonInstruction $inv.Step 0 0
    }
    catch {
        $threw = $true
        $rejectedCount++
    }
    if (-not $threw) {
        throw "Validation anomaly: Invalid case '$($inv.Name)' was accepted without throwing!"
    }
}

Write-Host "[+] Invalid Operands Tested: $($invalidCases.Count)"
Write-Host "[+] Invalid Operands Rejected: $rejectedCount"
if ($rejectedCount -eq $invalidCases.Count) {
    Write-Host "[+] Invalid Operand Rejection: 100% REJECTED" -ForegroundColor Green
}

# Cleanup temp files
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

[pscustomobject]@{
    TestedCases          = $testCases.Count
    EmittedBytes         = $pwshBytes.Length
    OracleBytes          = $oracleBytes.Length
    Mismatches           = $mismatchCount
    InvalidCasesTested   = $invalidCases.Count
    InvalidCasesRejected = $rejectedCount
    Pass                 = ($mismatchCount -eq 0 -and $rejectedCount -eq $invalidCases.Count)
}
