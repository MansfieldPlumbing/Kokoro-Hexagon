# Kokoro ratchet: accepted values per case. Floors only rise, ceilings only fall; changed only by Update-KokoroRatchet
# after a measured 'keep' (tools/Kokoro.Evaluator.psm1), and committed with the change that earned it.
# A Blocked case names what stops it from running; Test-KokoroRatchet counts blocked cases in every score line, so a
# capability gap stays visible until the case runs. Inputs under build/ are capture-derived and not committed.
# Timing passages: six fixed English passages from 1.5 to 28 s of audio, captured under build/capture-timing-passages/.
@{
    # Named setups: emitter parameters that override a case's accepted parameters
    # (Invoke-KokoroExperiment -Setup, Compare-KokoroSetup). Add a line to try a configuration.
    Setups = @{
        Baseline = @{}
        Threads2 = @{ ResidentHvxThreads = 2 }
        Threads3 = @{ ResidentHvxThreads = 3 }
        Batch16 = @{ ResidentBatchTiles = 16 }
        Batch32 = @{ ResidentBatchTiles = 32 }
        Batch44 = @{ ResidentBatchTiles = 44 }
    }
    Cases = @(
        @{
            Name = 'network-free-peach-sm8550'
            Audio = '2.125 s, 85 decoder frames; bank front end, af_heart'
            BaselineManifest = 'tools/baselines/bank-front-end-sm8550-20261010.manifest.psd1'
            Kernel = 'KokoroDecoderGenerator16Run'
            Parameters = @{ ResBlockFrames = 10201; ResidentHvxThreads = 4; ResidentBatchTiles = 14 }
            Input = 'data/baselines/network-free-peach-sm8550-20261010/input'
            Soc = 'SM8550'
            # Initial accepted values from the first three successful runs, not a change to an existing floor.
            PcmSnrDbFloor = 31.29
            ClippedCeiling = 0
            MedianMsCeiling = 148.495
            NoiseFraction = 0.03
            PcmSHA256 = 'E6456751BDBCCE0D5CB38DA8226B4EEC8B1C514E16626755C5BD975699374054'
        }
        @{
            Name = 'decoder-generator-hello-sm8550'
            Kernel = 'KokoroDecoderGenerator16Run'
            Parameters = @{ ResBlockFrames = 7801; ResidentHvxThreads = 4; ResidentBatchTiles = 22 }
            Input = 'build/decoder-generator-fixture-20261009'
            Soc = 'SM8550'
            PcmSnrDbFloor = 31.99
            ClippedCeiling = 0
            # Median of 5 unchanged runs on 2026-10-09 (106.887-110.18 ms, spread 3.0%); the receipt's 106.756 ms was
            # one 3-run sample at the low end of that spread.
            MedianMsCeiling = 109.677
            NoiseFraction = 0.03
            PcmSHA256 = '69F7977245142FA43D56C3582F67F23D8175C37203DA15AA97841A7CA97366F8'
        }
        @{
            Name = 'timing-passage-0-sm8550'
            Audio = '1.525 s, 61 decoder frames'
            Kernel = 'KokoroDecoderGenerator16Run'
            Parameters = @{ ResBlockFrames = 7321; ResidentHvxThreads = 4; ResidentBatchTiles = 22 }
            # New-KokoroJobInput -Reference build/decoder-generator-fixture-20261009 with the hello-world captures mapped
            # to build/capture-timing-passages/0-decoder and 0-generator; calibration unchanged.
            Input = 'build/evaluator/input/timing-passage-0/decoder-generator-fixture-20261009'
            Soc = 'SM8550'
            # First measurement, 2026-10-09; one 3-run sample.
            PcmSnrDbFloor = 28.49
            ClippedCeiling = 0
            MedianMsCeiling = 116.161
            NoiseFraction = 0.03
            PcmSHA256 = '6D871B3F54D6256A9F723B1E48DA4D3B47B58884A8738261343296BC4AD4CD7E'
        }
        @{ Name = 'timing-passage-1-sm8550'; Soc = 'SM8550'; Audio = '4.450 s, 178 decoder frames'; Capture = 'build/capture-timing-passages/1-*'
           Blocked = 'Decoder holds the whole sequence in VTCM (capacity 96 frames) and the generator is resident: needs halo-tiled streaming through DDR.' }
        @{ Name = 'timing-passage-2-sm8550'; Soc = 'SM8550'; Audio = '8.050 s, 322 decoder frames'; Capture = 'build/capture-timing-passages/2-*'
           Blocked = 'Decoder capacity 96 frames and resident generator: needs halo-tiled streaming.' }
        @{ Name = 'timing-passage-3-sm8550'; Soc = 'SM8550'; Audio = '16.250 s, 650 decoder frames'; Capture = 'build/capture-timing-passages/3-*'
           Blocked = 'Decoder capacity 96 frames and resident generator: needs halo-tiled streaming.' }
        @{ Name = 'timing-passage-4-sm8550'; Soc = 'SM8550'; Audio = '26.925 s, 1077 decoder frames'; Capture = 'build/capture-timing-passages/4-*'
           Blocked = 'Decoder capacity 96 frames and resident generator: needs halo-tiled streaming.' }
        @{ Name = 'timing-passage-5-sm8550'; Soc = 'SM8550'; Audio = '28.025 s, 1121 decoder frames'; Capture = 'build/capture-timing-passages/5-*'
           Blocked = 'Decoder capacity 96 frames and resident generator: needs halo-tiled streaming.' }
    )
}
