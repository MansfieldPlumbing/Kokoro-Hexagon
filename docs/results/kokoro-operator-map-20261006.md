# Kokoro operator map from the stock checkpoint

Inputs: `kokoro-v1_0.pth` (SHA-256 `496DBA11…F18AD1E4`) and `config.json`
from hexgrad/Kokoro-82M `f3ff3571`. Rates from hexgrad/kokoro `dfb907a0`
(`model.py:110-117`, `modules.py:99-105`, `istftnet.py:394-401`).
Tool: `tools/Get-KokoroOperatorMap.ps1`. One duration frame is 600 samples
(40 frames/s at 24 kHz). Token-rate stages assume 14 phonemes/s.

| Stage | Params (M) | GMAC per audio second | Share |
|---|---:|---:|---:|
| Generator, 60x stage (128 ch) | 3.57 | 15.52 | 56.5% |
| Generator, 10x stage (256 ch) | 13.72 | 9.07 | 33.0% |
| Decoder | 31.16 | 1.37 | 5.0% |
| ALBERT (one layer applied 12 times) | 6.01 | 0.93 | 3.4% |
| F0/N predictor | 7.23 | 0.38 | 1.4% |
| Duration predictor | 7.38 | 0.10 | 0.4% |
| Text encoder | 5.52 | 0.08 | 0.3% |
| Style projections (once per group) | 6.41 | 0 | 0% |
| **Total** | **81.76** | **27.45** | 100% |

The generator is 89.5% of the work and 21% of the weights; the decoder is
38% of the weights and 5% of the work. At 27.45 GMAC per audio second, the
HMX convolution throughput needed for a given real-time factor is
27.45 / RTF GMAC/s (0.1 RTF needs 275 GMAC/s sustained).

Counted: convolution, transposed convolution, linear and LSTM weights.
Not counted: AdaIN statistics, Snake, residual adds, the harmonic source,
STFT/iSTFT and attention softmax (HVX work).
