# ctrl.s: branches with divergent EXEC, exec.save/set/and/or, per-lane
# loops, kill, bar between the warps of a workgroup (LDS), wait.
        add     r1, lane, zero
        andi    r2, r1, 1               # odd lanes
        andi    r3, r1, 7               # per-lane trip count 0..7
        addi    r4, zero, 0             # accumulator
        addi    r9, zero, 0
        exec.save r10                   # all lanes
        # if (odd) r4 += 10 else r4 += 20
        exec.and r2
        bexz    1f_else
        addi    r4, r4, 10
1f_else:
        exec.set r10
        sltiu   r5, r2, 1               # even lanes (Boolean)
        exec.and r5
        bexz    endif1
        addi    r4, r4, 20
endif1:
        exec.set r10
        # per-lane loop: r4 += 3 for r3 iterations
loop:
        sltu    r6, zero, r3
        exec.and r6
        bexz    done
        addi    r4, r4, 3
        addi    r3, r3, -1
        j       loop
done:
        exec.set r10
        # uniform branches on Booleans
        bany    r2, any_taken
        addi    r9, r9, 1               # not reached: some lane is odd
any_taken:
        ball    r2, not_taken
        addi    r9, r9, 2
not_taken:
        bnone   r9, skip3               # r9 = 2 in every lane: not taken
        addi    r9, r9, 4
skip3:
        sltu    r7, r1, zero            # all zero
        bnone   r7, skip4
        addi    r9, r9, 8
skip4:
        bexnz   skip5
        addi    r9, r9, 16
skip5:
        # exec.or: lanes 0..3 plus odd lanes
        sltiu   r8, r1, 4
        exec.set r2
        exec.or r8
        addi    r9, r9, 32
        exec.set r10
        # workgroup barrier: each warp stores its slot, the other warp reads it
        slli    r13, lidn, 2
        sts     r4, 0(r13)
        bar
        xori    r14, r13, 128           # the other warp's lane (64 lanes = 2 warps)
        lds     r15, 0(r14)
        bar
        # kill the lanes >= 28: their sw is dropped, they keep running
        sltiu   r11, r1, 28
        xori    r11, r11, -1
        kill    r11
        add     r12, killed, zero
        slli    r16, lidn, 2
        sts     r9, 256(r16)            # dropped for the killed lanes
        movi    r17, 0x8000
        add     r17, r17, r16
        sw      r9, 0(r17)              # dropped for the killed lanes (0x8000 + 4 lidn)
        sw.x    r12, 256(r17)           # every EXEC lane
        wait    0, 0, 0
        nop
        end
