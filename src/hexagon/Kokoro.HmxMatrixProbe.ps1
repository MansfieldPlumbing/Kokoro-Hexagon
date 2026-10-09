#requires -Version 7.4
# Pure PowerShell V73 instruction sequence for Tri-Precision HMX Matrix Contraction Probes.
# Implements FP16, W8A8, and W4A8 single-tile contractions with four-timestamp hwticks telemetry.
# Zero C runtime. Zero compiler dependencies. Zero relocations. Zero imports.

function New-KokoroHmxMatrixSteps {
    $steps = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$Register, [uint32]$Value)
        $steps.Add(@{Op='lo'; x=$Register; i=($Value -band 65535)})
        $steps.Add(@{Op='hi'; x=$Register; i=($Value -shr 16)})
    }
    $intReadback = { param([int]$FinalStage)
        # Qualcomm's V73 integer accumulator protocol: four biased byte-plane
        # extracts followed by a fixed HVX interleave into 32-bit lanes.
        $steps.Add(@{Op='load'; d=8; s=29; Offset=20})
        foreach ($plane in @(@(0,4096), @(1024,6144), @(2048,8192), @(3072,10240))) {
            $steps.Add(@{Op='addi'; d=9; s=8; i=$plane[0]})
            $steps.Add(@{Op='bias-mxmem'; s=9})
            $steps.Add(@{Op='addi'; d=10; s=8; i=$plane[1]})
            $steps.Add(@{Op='imm'; d=11; i=0})
            $steps.Add(@{Op='mxmem-after-retain-cm-ub'; s=10; t=11})
        }

        $steps.Add(@{Op='addi'; d=2; s=8; i=4096})
        $steps.Add(@{Op='addi'; d=3; s=8; i=6144})
        $steps.Add(@{Op='addi'; d=4; s=8; i=8192})
        $steps.Add(@{Op='addi'; d=5; s=8; i=10240})
        $steps.Add(@{Op='load'; d=6; s=29; Offset=16})
        $steps.Add(@{Op='imm'; d=7; i=-1})
        $steps.Add(@{Op='imm'; d=1; i=-2})
        for ($i = 0; $i -lt 16; $i++) {
            $steps.Add(@{Op='vload-post'; d=0; s=2; i=1})
            $steps.Add(@{Op='vload-post'; d=1; s=4; i=1})
            $steps.Add(@{Op='vload-post'; d=2; s=3; i=1})
            $steps.Add(@{Op='vload-post'; d=4; s=5; i=1})
            $steps.Add(@{Op='vshuff'; d=2; s=2; t=0; r=7})
            $steps.Add(@{Op='vshuff'; d=30; s=4; t=1; r=7})
            $steps.Add(@{Op='vshuff'; d=4; s=30; t=2; r=1})
            $steps.Add(@{Op='vshuff'; d=6; s=31; t=3; r=1})
            foreach ($vector in 4..7) { $steps.Add(@{Op='vstore-post'; s=6; t=$vector; i=1}) }
        }
        $steps.Add(@{Op='load'; d=14; s=29; Offset=0})
        $steps.Add(@{Op='imm'; d=4; i=$FinalStage})
        $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    }

    # FastRPC Dispatch:
    # 0x00020001: open handle
    # 0x01000010: close handle
    # 0x02030100: invoke matrix probe (3 inputs, 1 output)
    foreach ($dispatch in @(@(0x00020001,'open'), @(0x01000010,'success'), @(0x02030100,'test_matrix'))) {
        & $imm 4 $dispatch[0]
        $steps.Add(@{Op='eq'; d=0; s=2; t=4})
        $steps.Add(@{Op='jump-p'; u=0; Label=$dispatch[1]})
    }
    $steps.Add(@{Op='imm'; d=0; i=20}); $steps.Add(@{Op='return'}) # AEE_EUNSUPPORTED

    # Open Handle
    $steps.Add(@{Op='label'; Name='open'})
    $steps.Add(@{Op='imm'; d=4; i=0})
    $steps.Add(@{Op='eq'; d=0; s=3; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='bad'})
    $steps.Add(@{Op='imm'; d=4; i=1}); $steps.Add(@{Op='store'; s=3; t=4; Offset=16})
    $steps.Add(@{Op='imm'; d=4; i=0}); $steps.Add(@{Op='store'; s=3; t=4; Offset=20})

    # Success Return
    $steps.Add(@{Op='label'; Name='success'})
    $steps.Add(@{Op='imm'; d=0; i=0}); $steps.Add(@{Op='return'})

    # Bad Parameter Return
    $steps.Add(@{Op='label'; Name='bad'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'}) # AEE_EBADPARM

    # Method 2: Test Matrix Contraction
    $steps.Add(@{Op='label'; Name='test_matrix'})
    $steps.Add(@{Op='imm'; d=15; i=0})
    $steps.Add(@{Op='eq'; d=0; s=3; t=15}); $steps.Add(@{Op='jump-p'; u=0; Label='bad'})

    # Config is { mode, vtcm_act, vtcm_weight, vtcm_output, vtcm_bias }.
    $steps.Add(@{Op='load'; d=4; s=3; Offset=4}) # pra[0].len
    $steps.Add(@{Op='imm'; d=5; i=19})
    $steps.Add(@{Op='gtu'; d=0; s=4; t=5}); $steps.Add(@{Op='jump-p'; u=0; Label='config_len_ok'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label'; Name='config_len_ok'})

    # Validate pra[3].len >= 64 (telemetry buffer of 32 bytes + 16 bytes status + 16 bytes padding)
    $steps.Add(@{Op='load'; d=4; s=3; Offset=28}) # pra[3].len
    $steps.Add(@{Op='imm'; d=5; i=63})
    $steps.Add(@{Op='gtu'; d=0; s=4; t=5}); $steps.Add(@{Op='jump-p'; u=0; Label='out_len_ok'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label'; Name='out_len_ok'})

    # Load input pointers:
    # pra[0].pv = config (precision selector: 0=Control, 1=FP16, 2=W8A8, 3=W4A8)
    # pra[1].pv = activation buffer
    # pra[2].pv = weight buffer
    # pra[3].pv = output buffer (telemetry + result)
    $steps.Add(@{Op='load'; d=8;  s=3; Offset=0})   # r8 = pra[0].pv
    $steps.Add(@{Op='load'; d=14; s=3; Offset=24})  # r14 = pra[3].pv (output/telemetry)

    # Load mode and process-resident VTCM pointers from config.
    $steps.Add(@{Op='load'; d=9; s=8; Offset=0})    # r9 = mode
    $steps.Add(@{Op='load'; d=10; s=8; Offset=4})   # r10 = VTCM activation
    $steps.Add(@{Op='load'; d=12; s=8; Offset=8})   # r12 = VTCM weight
    $steps.Add(@{Op='load'; d=7;  s=8; Offset=12})  # r7 = VTCM output
    $steps.Add(@{Op='load'; d=6;  s=8; Offset=16})  # r6 = VTCM bias/config

    # Allocate 32-byte frame on stack and preserve critical registers
    $steps.Add(@{Op='addi'; d=29; s=29; i=-32})
    $steps.Add(@{Op='store'; s=29; t=14; Offset=0})  # memw(r29 + 0) = r14 (output ptr)
    $steps.Add(@{Op='store'; s=29; t=10; Offset=4})  # memw(r29 + 4) = r10 (act ptr)
    $steps.Add(@{Op='store'; s=29; t=12; Offset=8})  # memw(r29 + 8) = r12 (weight ptr)
    $steps.Add(@{Op='store'; s=29; t=9;  Offset=12}) # memw(r29 + 12) = r9 (mode)
    $steps.Add(@{Op='store'; s=29; t=7;  Offset=16}) # memw(r29 + 16) = VTCM output ptr
    $steps.Add(@{Op='store'; s=29; t=6;  Offset=20}) # memw(r29 + 20) = VTCM bias ptr

    # Initialize telemetry slots in output buffer
    $steps.Add(@{Op='imm'; d=4; i=0})
    $steps.Add(@{Op='store-d'; s=14; t=4; Offset=0})   # T0 = 0
    $steps.Add(@{Op='store-d'; s=14; t=4; Offset=8})   # T1 = 0
    $steps.Add(@{Op='store-d'; s=14; t=4; Offset=16})  # T2 = 0
    $steps.Add(@{Op='store-d'; s=14; t=4; Offset=24})  # T3 = 0
    $steps.Add(@{Op='store';   s=14; t=4; Offset=32})  # hvx_unlock_rc = 0
    $steps.Add(@{Op='store';   s=14; t=4; Offset=36})  # hmx_try_lock_rc = 0
    $steps.Add(@{Op='store';   s=14; t=4; Offset=40})  # hmx_unlock_rc = 0
    $steps.Add(@{Op='store';   s=14; t=4; Offset=44})  # hvx_relock_rc = 0
    $steps.Add(@{Op='store';   s=14; t=4; Offset=48})  # step_reached = 0

    # T0: Read 64-bit hardware processor ticks immediately before mode switch
    $steps.Add(@{Op='hwticks'; d=0})                   # r1:0 = c31:30 (T0)
    $steps.Add(@{Op='store-d'; s=14; t=0; Offset=0})   # Store T0

    # Step 1: Unlock HVX context
    # qurt_hvx_unlock(): r0 = #3, r5 = #0, trap0(#0x55)
    $steps.Add(@{Op='imm'; d=0; i=3})
    $steps.Add(@{Op='imm'; d=5; i=0})
    $steps.Add(@{Op='trap0'; i=0x55})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0})     # Reload r14 from stack
    $steps.Add(@{Op='store'; s=14; t=0; Offset=32})    # Store hvx_unlock_rc

    # Step 2: Try lock HMX context
    # qurt_hmx_try_lock(): r5 = #2, trap0(#0x1d)
    $steps.Add(@{Op='imm'; d=5; i=2})
    $steps.Add(@{Op='trap0'; i=0x1d})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=36})    # Store hmx_try_lock_rc

    # T1: Read 64-bit timestamp immediately after HMX acquisition
    $steps.Add(@{Op='hwticks'; d=2})                   # r3:2 = c31:30 (T1)
    $steps.Add(@{Op='store-d'; s=14; t=2; Offset=8})   # Store T1

    # Check if hmx_try_lock succeeded (hmx_try_lock_rc == 0)
    $steps.Add(@{Op='load'; d=1; s=14; Offset=36})
    $steps.Add(@{Op='imm'; d=2; i=0})
    $steps.Add(@{Op='eq'; d=0; s=1; t=2})
    $steps.Add(@{Op='jump-p'; u=0; Label='hmx_locked_ok'})

    # If lock failed, jump straight to HVX restoration
    $steps.Add(@{Op='eq'; d=0; s=0; t=0})              # p0 = true
    $steps.Add(@{Op='jump-p'; u=0; Label='restore_hvx'})

    # Branch on precision selector mode (r9):
    # Mode 0: Control / Empty scaffolding -> skip computation
    # Mode 1: FP16
    # Mode 2: W8A8
    # Mode 3: W4A8
    # Mode 9: FP16 accumulator conversion only (no mxmem)
    # Mode 10: FP16 conversion followed by an mxmem write
    $steps.Add(@{Op='label'; Name='hmx_locked_ok'})
    $steps.Add(@{Op='load'; d=9;  s=29; Offset=12})    # Reload mode
    $steps.Add(@{Op='load'; d=10; s=29; Offset=4})     # Reload act ptr
    $steps.Add(@{Op='load'; d=12; s=29; Offset=8})     # Reload wt ptr

    $steps.Add(@{Op='imm'; d=4; i=0})
    $steps.Add(@{Op='eq'; d=0; s=9; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    $steps.Add(@{Op='imm'; d=4; i=1})
    $steps.Add(@{Op='eq'; d=0; s=9; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='exec_fp16'})

    $steps.Add(@{Op='imm'; d=4; i=2})
    $steps.Add(@{Op='eq'; d=0; s=9; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='exec_w8a8'})

    $steps.Add(@{Op='imm'; d=4; i=3})
    $steps.Add(@{Op='eq'; d=0; s=9; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='exec_w4a8'})

    $steps.Add(@{Op='imm'; d=4; i=9})
    $steps.Add(@{Op='eq'; d=0; s=9; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='exec_cvt_only'})

    $steps.Add(@{Op='imm'; d=4; i=10})
    $steps.Add(@{Op='eq'; d=0; s=9; t=4}); $steps.Add(@{Op='jump-p'; u=0; Label='exec_cvt_write'})

    $steps.Add(@{Op='eq'; d=0; s=0; t=0})
    $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    # --- Precision 1: FP16 Contraction ---
    $steps.Add(@{Op='label'; Name='exec_fp16'})
    $steps.Add(@{Op='mxclracc.hf'})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=11}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='imm'; d=11; i=32767})              # HexKL FP16 activation descriptor
    $steps.Add(@{Op='imm'; d=13; i=1920})               # HexKL FP16 weight descriptor
    $steps.Add(@{Op='mxmpy-fp16'; s=10; t=11; u=12; v=13}) # Ingest and accumulate
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=12}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='load'; d=8; s=29; Offset=20})     # HexKL FP16 scale/bias table
    $steps.Add(@{Op='bias-mxmem2'; s=8})               # bias = mxmem2(r8)
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=13}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='load'; d=6; s=29; Offset=16})     # r6 = VTCM output
    $steps.Add(@{Op='imm'; d=7; i=0})
    $steps.Add(@{Op='mxmem-after-hf'; s=6; t=7})       # HexKL accumulator read
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=14}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='eq'; d=0; s=0; t=0})
    $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    # --- Precision 2: W8A8 Contraction ---
    $steps.Add(@{Op='label'; Name='exec_w8a8'})
    $steps.Add(@{Op='mxclracc'})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=21}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='imm'; d=11; i=31})                 # HexKL W8A8 activation descriptor
    $steps.Add(@{Op='imm'; d=13; i=896})                # HexKL W8A8 weight descriptor
    $steps.Add(@{Op='mxmpy-w8a8-cm'; s=10; t=11; u=12; v=13}) # HexKL 64x32 activation
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=22}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    & $intReadback 24
    $steps.Add(@{Op='eq'; d=0; s=0; t=0})
    $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    # --- Precision 3: W4A8 Contraction ---
    $steps.Add(@{Op='label'; Name='exec_w4a8'})
    $steps.Add(@{Op='mxclracc'})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=31}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='imm'; d=11; i=31})                 # HexKL W4A8 activation descriptor
    $steps.Add(@{Op='imm'; d=13; i=384})                # HexKL W4A8 weight descriptor
    $steps.Add(@{Op='mxmpy-w4a8-cm'; s=10; t=11; u=12; v=13}) # HexKL 64x32 activation
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=32}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    & $intReadback 34
    $steps.Add(@{Op='eq'; d=0; s=0; t=0})
    $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    # --- Mode 9: CvtOnly Diagnostic (no mxmem reads or writes) ---
    $steps.Add(@{Op='label'; Name='exec_cvt_only'})
    $steps.Add(@{Op='mxclracc.hf'})
    $steps.Add(@{Op='imm'; d=7; i=0})
    $steps.Add(@{Op='cvt-hf'; s=7})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=93}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='eq'; d=0; s=0; t=0})
    $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    # --- Mode 10: CvtWrite Diagnostic (no mxmem reads, only accumulator + cvt + mxmem write) ---
    $steps.Add(@{Op='label'; Name='exec_cvt_write'})
    $steps.Add(@{Op='mxclracc.hf'})                     # Clear FP16 accumulator (proven to work)
    $steps.Add(@{Op='imm'; d=7; i=0})                   # r7 = scale/bias control
    $steps.Add(@{Op='cvt-hf'; s=7})                     # cvt.hf = acc(r7) — convert zero accumulator
    $steps.Add(@{Op='load'; d=6; s=29; Offset=16})       # r6 = VTCM output
    $steps.Add(@{Op='imm'; d=7; i=64})                   # r7 = output stride (64 bytes)
    $steps.Add(@{Op='mxmem-cvt'; s=6; t=7})              # mxmem(r6, r7) = cvt — write zero result to DDR
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0}); $steps.Add(@{Op='imm'; d=4; i=104}); $steps.Add(@{Op='store'; s=14; t=4; Offset=48})
    $steps.Add(@{Op='eq'; d=0; s=0; t=0})
    $steps.Add(@{Op='jump-p'; u=0; Label='done_compute'})

    # T2: Read 64-bit timestamp immediately after computation, before HMX unlock
    $steps.Add(@{Op='label'; Name='done_compute'})
    $steps.Add(@{Op='hwticks'; d=4})                   # r5:4 = c31:30 (T2)
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0})
    $steps.Add(@{Op='store-d'; s=14; t=4; Offset=16})  # Store T2

    # Step 3: Unlock HMX
    # qurt_hmx_unlock2(0): r0 = #0, r5 = #1, trap0(#0x1d)
    $steps.Add(@{Op='imm'; d=0; i=0})
    $steps.Add(@{Op='imm'; d=5; i=1})
    $steps.Add(@{Op='trap0'; i=0x1d})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=40})    # Store hmx_unlock_rc

    # Step 4: Relock HVX context
    # qurt_hvx_lock(1): r0 = #1, r5 = #0, trap0(#0x55)
    $steps.Add(@{Op='label'; Name='restore_hvx'})
    $steps.Add(@{Op='imm'; d=0; i=1})
    $steps.Add(@{Op='imm'; d=5; i=0})
    $steps.Add(@{Op='trap0'; i=0x55})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=0})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=44})    # Store hvx_relock_rc

    # T3: Read 64-bit timestamp after HMX unlock and HVX relock
    $steps.Add(@{Op='hwticks'; d=6})                   # r7:6 = c31:30 (T3)
    $steps.Add(@{Op='store-d'; s=14; t=6; Offset=24})  # Store T3

    # Deallocate stack frame and return success
    $steps.Add(@{Op='addi'; d=29; s=29; i=32})
    $steps.Add(@{Op='imm'; d=0; i=0})
    $steps.Add(@{Op='return'})

    $steps
}
