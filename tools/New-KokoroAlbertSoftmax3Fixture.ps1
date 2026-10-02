#requires -Version 7.4
[CmdletBinding()]
param(
    [string] $QkvFixtureDirectory = (Join-Path $PSScriptRoot '..\build\albert-qkv-vector-fixture-001'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\build\albert-softmax3-fixture-001')
)

$ErrorActionPreference = 'Stop'
$sourceManifestPath = Join-Path $QkvFixtureDirectory 'fixture.json'
$sourceManifestBytes = [IO.File]::ReadAllBytes($sourceManifestPath)
$sourceManifest = [Text.Json.JsonDocument]::Parse([Text.Encoding]::UTF8.GetString($sourceManifestBytes))
try {
    $source = $sourceManifest.RootElement
    if ($source.GetProperty('Role').GetString() -ne 'stock_albert_attention_fused_qkv_differential_fixture' -or
        $source.GetProperty('Rows').GetInt32() -ne 3 -or
        $source.GetProperty('OutputChannels').GetInt32() -ne 2304) {
        throw 'QKV source fixture contract differs.'
    }
    $expectedRecord = $source.GetProperty('Expected')
    $qkvPath = Join-Path $QkvFixtureDirectory $expectedRecord.GetProperty('Name').GetString()
    $qkvBytes = [IO.File]::ReadAllBytes($qkvPath)
    if ($qkvBytes.Length -ne $expectedRecord.GetProperty('Bytes').GetInt32() -or
        (Get-FileHash -LiteralPath $qkvPath).Hash -ne $expectedRecord.GetProperty('SHA256').GetString()) {
        throw 'QKV source fixture integrity differs.'
    }
    $qkv = [float[]]::new($qkvBytes.Length / 4)
    [Buffer]::BlockCopy($qkvBytes, 0, $qkv, 0, $qkvBytes.Length)
    $inputs = [float[]]::new(36 * 3)
    $expected = [float[]]::new(36 * 3)
    $operator = Join-Path $PSScriptRoot '..\src\models\Invoke-KokoroAlbertShiftedSoftmax3.ps1'
    $scale = 1.0 / [Math]::Sqrt(64.0)
    $case = 0
    for ($head = 0; $head -lt 12; $head++) {
        for ($queryToken = 0; $queryToken -lt 3; $queryToken++) {
            $scores = [float[]]::new(3)
            for ($keyToken = 0; $keyToken -lt 3; $keyToken++) {
                $dot = 0.0
                for ($dimension = 0; $dimension -lt 64; $dimension++) {
                    $q = $qkv[$queryToken * 2304 + $head * 64 + $dimension]
                    $k = $qkv[$keyToken * 2304 + 768 + $head * 64 + $dimension]
                    $dot += [double]$q * $k
                }
                $scores[$keyToken] = [float]($dot * $scale)
            }
            $maximum = ($scores | Measure-Object -Maximum).Maximum
            $shifted = [float[]]@(
                [float]($scores[0] - $maximum),
                [float]($scores[1] - $maximum),
                [float]($scores[2] - $maximum)
            )
            if (($shifted | Measure-Object -Minimum).Minimum -lt -64.0) {
                throw 'QKV source fixture exceeds the admitted shifted-score domain.'
            }
            $probabilities = & $operator -ShiftedScores $shifted
            [Array]::Copy($shifted, 0, $inputs, 3 * $case, 3)
            [Array]::Copy($probabilities, 0, $expected, 3 * $case, 3)
            $case++
        }
    }
    if ($case -ne 36) { throw 'Unexpected softmax fixture case count.' }

    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $write = { param([string] $Name, [float[]] $Values)
        $path = Join-Path $OutputDirectory $Name
        if ([IO.File]::Exists($path)) { throw "Fixture output already exists: $path" }
        $bytes = [byte[]]::new(4 * $Values.Length)
        [Buffer]::BlockCopy($Values, 0, $bytes, 0, $bytes.Length)
        [IO.File]::WriteAllBytes($path, $bytes)
        [ordered]@{Name=$Name;Bytes=$bytes.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash}
    }
    $inputRecord = & $write 'input.f32' $inputs
    $expectedOutputRecord = & $write 'expected.f32' $expected
    $manifest = [ordered]@{
        Schema = 1
        Role = 'stock_albert_attention_shifted_softmax3_differential_fixture'
        Cases = 36
        ElementsPerCase = 3
        Approximation = 'taylor7_x_over_64_then_six_squares_fp32'
        SourceManifestSHA256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceManifestBytes))
        SourceQkvSHA256 = $expectedRecord.GetProperty('SHA256').GetString()
        Input = $inputRecord
        Expected = $expectedOutputRecord
    }
    $manifestPath = Join-Path $OutputDirectory 'fixture.json'
    if ([IO.File]::Exists($manifestPath)) { throw "Fixture output already exists: $manifestPath" }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5))
    [pscustomobject]@{Path=$OutputDirectory;Cases=36;ManifestSHA256=(Get-FileHash -LiteralPath $manifestPath).Hash}
}
finally {
    $sourceManifest.Dispose()
    foreach ($buffer in @($qkvBytes,$qkv,$inputs,$expected)) {
        if ($null -ne $buffer) { [Array]::Clear($buffer,0,$buffer.Length) }
    }
}
