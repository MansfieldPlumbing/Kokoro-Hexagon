#Requires -Version 7.4
<#
.SYNOPSIS
Counts multiply-accumulates per Kokoro stage from the stock checkpoint shapes.

.DESCRIPTION
Rates follow hexgrad/kokoro dfb907a0: model.py:110-117 expands tokens to duration
frames (F); modules.py:99-105 and istftnet.py:399 upsample the F0/N blocks and the
last decoder block to 2F; the generator upsamples 10x then 6x (config.json) and the
iSTFT hop is 5, so one frame is 600 samples (40 frames/s at 24 kHz). ALBERT applies
its one shared layer num_hidden_layers times. AdaIN and AdaLayerNorm style
projections (`*.fc.*`) run once per breath group, not per frame.

Conv1d MACs per output step = out * in/groups * k. ConvTranspose1d = in * out/groups
* k / stride. Linear = out * in. LSTM = weight_ih + weight_hh per step and direction.
#>
param(
    [string] $Checkpoint = (Join-Path $PSScriptRoot '../build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987/kokoro-v1_0.pth'),
    [string] $Config = (Join-Path $PSScriptRoot '../build/inputs/kokoro/f3ff3571791e39611d31c381e3a41a3af07b4987/config.json'),
    [ValidateRange(1, 100)][double] $PhonemesPerSecond = 14,
    [switch] $PerTensor
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cfg = Get-Content $Config -Raw | ConvertFrom-Json -AsHashtable
$reader = [scriptblock]::Create([IO.File]::ReadAllText((Join-Path $root 'src/runspace/Torch.Checkpoint.psm1'))).InvokeReturnAsIs()
$ck = & $reader.Read (Resolve-Path $Checkpoint).Path

$framesPerSecond = 24000 / (($cfg['istftnet']['upsample_rates'] | ForEach-Object -Begin { $p = 2 } -Process { $p *= $_ } -End { $p }) * $cfg['istftnet']['gen_istft_hop_size'])
$albertRepeat = $cfg['plbert']['num_hidden_layers']
$up0 = $cfg['istftnet']['upsample_rates'][0]
$up1 = $cfg['istftnet']['upsample_rates'][1]

# Each rule: name pattern, stage, steps per frame (T = token rate), repeat.
$tokenRate = $PhonemesPerSecond / $framesPerSecond
$rules = @(
    ,@('^bert\.module\.(embeddings|pooler)\.', $null, 0, 1)
    ,@('^bert\.module\.encoder\.embedding_hidden_mapping_in\.', 'ALBERT', $tokenRate, 1)
    ,@('^bert\.module\.encoder\.', 'ALBERT', $tokenRate, $albertRepeat)
    ,@('^bert_encoder\.', 'ALBERT', $tokenRate, 1)
    ,@('\.fc\.(weight|bias)$', 'Style (once per group)', 0, 1)
    ,@('^text_encoder\.module\.embedding\.', $null, 0, 1)
    ,@('^text_encoder\.', 'Text encoder', $tokenRate, 1)
    ,@('^predictor\.module\.(text_encoder|lstm|duration_proj)\.', 'Duration predictor', $tokenRate, 1)
    ,@('^predictor\.module\.shared\.', 'F0/N predictor', 1, 1)
    ,@('^predictor\.module\.(F0|N)\.0\.', 'F0/N predictor', 1, 1)
    ,@('^predictor\.module\.(F0|N)\.[12]\.', 'F0/N predictor', 2, 1)
    ,@('^predictor\.module\.(F0|N)_proj\.', 'F0/N predictor', 2, 1)
    ,@('^decoder\.module\.(F0_conv|N_conv|asr_res|encode)\.', 'Decoder', 1, 1)
    ,@('^decoder\.module\.decode\.[012]\.', 'Decoder', 1, 1)
    ,@('^decoder\.module\.decode\.3\.', 'Decoder', 2, 1)
    ,@('^decoder\.module\.generator\.m_source\.', 'Generator source', (2 * $up0 * $up1 * $cfg['istftnet']['gen_istft_hop_size']), 1)
    ,@('^decoder\.module\.generator\.(ups\.0|resblocks\.[012]|noise_convs\.0|noise_res\.0)\.', "Generator ${up0}x stage", (2 * $up0), 1)
    ,@('^decoder\.module\.generator\.(ups\.1|resblocks\.[345]|noise_convs\.1|noise_res\.1|conv_post)\.', "Generator $($up0*$up1)x stage", (2 * $up0 * $up1), 1)
)

function Get-Rule([string] $Name) {
    foreach ($r in $rules) { if ($Name -match $r[0]) { return ,$r } }
    throw "No rate rule for $Name"
}

$rows = foreach ($name in $ck.Tensors.Keys) {
    $t = $ck.Tensors[$name]
    $rule = Get-Rule $name
    $isWeight = $name -match '(weight|weight_v|weight_ih_l0|weight_hh_l0|weight_ih_l0_reverse|weight_hh_l0_reverse)$' -and $t.Shape.Length -ge 2
    [long] $macs = 0
    if ($isWeight -and $rule[1]) {
        $macs = 1; foreach ($d in $t.Shape) { $macs *= $d }
        if ($name -match '\.(ups\.\d+|pool)\.') {
            $stride = if ($name -match 'ups\.0') { $up0 } elseif ($name -match 'ups\.1') { $up1 } else { 2 }
            $macs = [long]($macs / $stride)
        }
    }
    [pscustomobject]@{
        Name = $name; Stage = $rule[1]; Params = [long]$t.Count
        MacsPerStep = $macs
        MacsPerSecond = [double]$macs * $rule[2] * $rule[3] * $framesPerSecond
    }
}

if ($PerTensor) { return $rows | Where-Object MacsPerSecond -gt 0 | Sort-Object MacsPerSecond -Descending }

$total = ($rows | Measure-Object MacsPerSecond -Sum).Sum
$rows | Where-Object Stage | Group-Object Stage | ForEach-Object {
    $m = ($_.Group | Measure-Object MacsPerSecond -Sum).Sum
    [pscustomobject]@{
        Stage = $_.Name
        ParamsM = [math]::Round((($_.Group | Measure-Object Params -Sum).Sum) / 1e6, 2)
        GMacPerAudioSecond = [math]::Round($m / 1e9, 3)
        Share = '{0:P1}' -f ($m / $total)
    }
} | Sort-Object GMacPerAudioSecond -Descending
[pscustomobject]@{ Stage = 'Total'; ParamsM = [math]::Round((($rows | Measure-Object Params -Sum).Sum) / 1e6, 2); GMacPerAudioSecond = [math]::Round($total / 1e9, 3); Share = '100%' }
