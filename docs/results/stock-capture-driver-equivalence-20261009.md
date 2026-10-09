# Stock capture driver equivalence, Windows, 2026-10-09

`Invoke-KokoroHexagon.ps1 StockCapture` replaces `tools/reference/Export-KokoroGeneratorCapture.ps1`. Both drivers
ran on the decoder block with the same arguments (hello world, af_heart, seed 17) into new `build/` directories. The
reference Python capturers (`tools/reference/capture_stock_*.py`) are unchanged and remain the stock comparison source.

| Guarantee of the old driver | Evidence for StockCapture |
| --- | --- |
| Stock commit equals `lib/manifest.json` `kokoroSource.commit` | same check and constant |
| Extracted stock source equals the pinned Git blobs | same 7 files, Git blobs and SHA-256 recorded |
| Checkpoint, config and voice: pinned length and SHA-256 | same 3 inputs and hashes recorded |
| Output only under `build/` | `%TEMP%` output refused before Python ran; nothing created |
| Output directory must be new | existing directory refused before Python ran |
| Provenance in `capture.json` | all fields equal except `exportToolSha256` (now the entrypoint's hash) |
| Captured tensors | 167 of 167 equal by SHA-256 and length; `moduleContracts` equal |

Differences: Python runs with `-I` (isolated: no `PYTHON*` variables or user site-packages; output unchanged above), and
the interpreter path is a constant rather than a `-Python` parameter. Default directory names are
`build/stock-<block>-capture-<UTC time>`.

Commit: the commit that adds this file and deletes the old driver.
