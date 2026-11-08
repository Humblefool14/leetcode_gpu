# sub.s: the lane unit: quad ops (qdx qdy qswap1-3 qbcast) and, with
# --subgroup, shfl (idx xor up down rot), vote.any/all and ballot, also
# under a divergent EXEC.
        add     r1, lane, zero
        fcvt.s.w r2, r1
        fmul.s  r3, r2, r2              # lane^2
        qdx     r4, r3
        qdy     r5, r3
        qswap1  r6, r1
        qswap2  r7, r1
        qswap3  r8, r1
        qbcast  r9, r3
        xori    r10, r1, 31             # reverse index
        shfl.idx r11, r3, r10
        addi    r12, zero, 5
        shfl.xor r13, r1, r12
        addi    r14, zero, 3
        shfl.up r15, r1, r14
        shfl.down r16, r1, r14
        shfl.rot r17, r1, r12
        andi    r18, r1, 1
        vote.any r19, r18
        vote.all r20, r18
        ballot  r21, r18
        sltiu   r22, r1, 64
        vote.all r23, r22
        # divergent: only lanes 8..23
        exec.save r24
        sltiu   r25, r1, 24
        exec.and r25
        sltiu   r26, r1, 8
        xori    r26, r26, -1
        exec.and r26
        ballot  r27, r18
        shfl.idx r28, r1, r12           # lane 5 is outside EXEC: own value
        vote.any r29, r26
        exec.set r24
        qdx     r30, r1
        end
