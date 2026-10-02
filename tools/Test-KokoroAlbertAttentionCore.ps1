#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$core = [IO.Path]::GetFullPath([IO.Path]::Combine(
    $PSScriptRoot, '..', 'src', 'models', 'Invoke-KokoroAlbertAttentionCore.ps1'))
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($core, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'ALBERT attention-core source does not parse.' }

# Zero scores make softmax uniform. This independently fixes the head layout,
# token layout, masking convention, and value-context equation.
$query = [float[]]::new(24)
$key = [float[]]::new(24)
$value = [float[]]::new(24)
foreach ($token in 0..2) {
    $base = @(1, 11, 31)[$token]
    foreach ($dimension in 0..7) { $value[$token * 8 + $dimension] = [float]($base + $dimension) }
}
$all = & $core -Query $query -Key $key -Value $value -Tokens 3 -HiddenSize 8 -Heads 2
$masked = & $core -Query $query -Key $key -Value $value -Tokens 3 -HiddenSize 8 -Heads 2 `
    -KeyMask ([bool[]]@($true, $false, $true))
for ($token = 0; $token -lt 3; $token++) {
    for ($dimension = 0; $dimension -lt 8; $dimension++) {
        $expectedAll = [float]((43.0 / 3.0) + $dimension)
        $expectedMasked = [float](16 + $dimension)
        if ([Math]::Abs($all[$token * 8 + $dimension] - $expectedAll) -gt 1e-6 -or
            [Math]::Abs($masked[$token * 8 + $dimension] - $expectedMasked) -gt 1e-6) {
            throw 'ALBERT attention-core uniform context differs.'
        }
    }
}

# Gate the full operator against its pre-extraction output for a deterministic
# masked fixture. A byte hash catches any change to Q/K/V, core, dense,
# residual, or LayerNorm composition.
$hidden = [float[]]::new(24)
for ($i = 0; $i -lt $hidden.Length; $i++) { $hidden[$i] = [float][Math]::Sin(($i + 1) * 0.17) }
$parameters = @{}
foreach ($name in 'query','key','value','dense') {
    $weights = [float[]]::new(64); $bias = [float[]]::new(8)
    for ($i = 0; $i -lt 64; $i++) {
        $weights[$i] = [float]([Math]::Sin(($i + 1) * (0.011 + 0.001 * $name.Length)) * 0.15)
    }
    for ($i = 0; $i -lt 8; $i++) { $bias[$i] = [float](($i - 3.5) * 0.003) }
    $parameters["$name.weight"] = $weights; $parameters["$name.bias"] = $bias
}
$parameters['LayerNorm.weight'] = [float[]](0..7 | ForEach-Object { [float](0.95 + $_ * 0.01) })
$parameters['LayerNorm.bias'] = [float[]](0..7 | ForEach-Object { [float](($_ - 3.5) * 0.002) })
$full = & ([IO.Path]::Combine([IO.Path]::GetDirectoryName($core), 'Invoke-KokoroAlbertAttention.ps1')) `
    -HiddenStates $hidden -Parameters $parameters -Tokens 3 -HiddenSize 8 -Heads 2 `
    -KeyMask ([bool[]]@($true, $false, $true))
$bytes = [byte[]]::new($full.Length * 4)
[Buffer]::BlockCopy($full, 0, $bytes, 0, $bytes.Length)
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
if ($hash -cne '540E5A2B5433071CCB57D6A07F1E2A23F0C92097AB8F03AF23D0B5B0DDAC2305') {
    throw 'Full ALBERT attention changed across attention-core extraction.'
}

$rejected = $false
try { $null = & $core -Query $query -Key $key -Value $value -Tokens 3 -HiddenSize 8 -Heads 2 -KeyMask ([bool[]]@($false,$false,$false)) } catch { $rejected = $true }
if (-not $rejected) { throw 'An all-masked ALBERT attention row was admitted.' }

[pscustomobject]@{
    UniformSoftmaxVerified = $true
    KeyMaskVerified = $true
    HeadLayoutVerified = $true
    FullAttentionSHA256 = $hash
    AllMaskedRejected = $true
    DeviceExecuted = $false
    Passed = $true
}
