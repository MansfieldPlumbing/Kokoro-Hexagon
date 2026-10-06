#requires -Version 7.4
# Pure PowerShell V73 instruction sequence for probing HMX availability on Hexagon V73.
# Directly invokes QuRT trap0(#0x1d) for HMX acquisition, lock, and unlock.
# Zero runtime C compiler. Zero imports. Zero relocations.

function New-KokoroHmxLockSteps {
    $steps = [Collections.Generic.List[hashtable]]::new()
    $imm = { param([int]$Register, [uint32]$Value)
        $steps.Add(@{Op='lo'; x=$Register; i=($Value -band 65535)})
        $steps.Add(@{Op='hi'; x=$Register; i=($Value -shr 16)})
    }

    # Dispatch:
    # 0x00020001: open handle
    # 0x01000010: close handle
    # 0x02010100: test_hmx (1 in, 1 out)
    foreach ($dispatch in @(@(0x00020001,'open'), @(0x01000010,'success'), @(0x02010100,'test_hmx'))) {
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

    # Method 2: Test HMX Lock
    $steps.Add(@{Op='label'; Name='test_hmx'})
    $steps.Add(@{Op='imm'; d=15; i=0})
    $steps.Add(@{Op='eq'; d=0; s=3; t=15}); $steps.Add(@{Op='jump-p'; u=0; Label='bad'})

    # Validate pra[1].len >= 16 (output buffer of 4 x int32)
    $steps.Add(@{Op='load'; d=4; s=3; Offset=12}) # pra[1].len
    $steps.Add(@{Op='imm'; d=5; i=15})
    $steps.Add(@{Op='gtu'; d=0; s=4; t=5}); $steps.Add(@{Op='jump-p'; u=0; Label='out_len_ok'})
    $steps.Add(@{Op='imm'; d=0; i=14}); $steps.Add(@{Op='return'})
    $steps.Add(@{Op='label'; Name='out_len_ok'})

    # r14 = pra[1].pv (output pointer)
    $steps.Add(@{Op='load'; d=14; s=3; Offset=8})
    # Preserve r14 on the stack (r29 - 8) across trap0 syscalls
    $steps.Add(@{Op='store'; s=29; t=14; Offset=-8})

    # Initialize all 4 output slots to -999 (0xFFFFFFA9)
    $steps.Add(@{Op='addi'; d=10; s=15; i=-999})
    $steps.Add(@{Op='store'; s=14; t=10; Offset=0})
    $steps.Add(@{Op='store'; s=14; t=10; Offset=4})
    $steps.Add(@{Op='store'; s=14; t=10; Offset=8})
    $steps.Add(@{Op='store'; s=14; t=10; Offset=12})

    # Step 1: Explicitly unlock HVX on this thread to allow HMX admission
    # qurt_hvx_unlock(): r0 = #3, r5 = #0, trap0(#85)
    $steps.Add(@{Op='imm'; d=0; i=3})
    $steps.Add(@{Op='imm'; d=5; i=0})
    $steps.Add(@{Op='trap0'; i=85})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=-8})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=0}) # out[0] = hvx_unlock_rc

    # Step 2: Try qurt_hmx_try_lock()
    # r5 = #2, trap0(#29)
    $steps.Add(@{Op='imm'; d=5; i=2})
    $steps.Add(@{Op='trap0'; i=29})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=-8})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=4}) # out[1] = hmx_try_lock_rc

    # Check if hmx_try_lock succeeded (r0 == 0)
    $steps.Add(@{Op='imm'; d=1; i=0})
    $steps.Add(@{Op='eq'; d=0; s=0; t=1})
    $steps.Add(@{Op='jump-p'; u=0; Label='do_hmx_unlock'})
    $steps.Add(@{Op='eq'; d=0; s=1; t=1}) # p0 = true
    $steps.Add(@{Op='jump-p'; u=0; Label='restore_hvx'})

    # Branch: do_hmx_unlock
    $steps.Add(@{Op='label'; Name='do_hmx_unlock'})
    # Execute physical HMX instruction while locked
    $steps.Add(@{Op='mxclracc'})
    # qurt_hmx_unlock2(0): r0 = #0, r5 = #1, trap0(#29)
    $steps.Add(@{Op='imm'; d=0; i=0})
    $steps.Add(@{Op='imm'; d=5; i=1})
    $steps.Add(@{Op='trap0'; i=29})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=-8})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=8}) # out[2] = hmx_unlock_rc

    # Step 3: Re-enable HVX on this thread: qurt_hvx_lock(128B = 1)
    # r0 = #1, r5 = #0, trap0(#85)
    $steps.Add(@{Op='label'; Name='restore_hvx'})
    $steps.Add(@{Op='imm'; d=0; i=1})
    $steps.Add(@{Op='imm'; d=5; i=0})
    $steps.Add(@{Op='trap0'; i=85})
    $steps.Add(@{Op='load'; d=14; s=29; Offset=-8})
    $steps.Add(@{Op='store'; s=14; t=0; Offset=12}) # out[3] = hvx_relock_rc

    $steps.Add(@{Op='label'; Name='done'})
    $steps.Add(@{Op='imm'; d=0; i=0})
    $steps.Add(@{Op='return'})

    return $steps.ToArray()
}
