# pk.s: the packed 16-bit unit (run with --packed): fp16 pairs from packh,
# every packed op, half selects, modifiers, .sat, unpackh, swaph.
        add     r1, lidn, zero
        addi    r2, r1, -10
        fcvt.s.w r3, r2                 # -10 .. 53
        movi    r4, 0x3ec00000          # 0.375
        fmul.s  r5, r3, r4
        packh   r6, r5, r3              # {f16(r3), f16(r5)}
        packh   r7, r4, r5
        fadd2   r8, r6, r7
        fsub2   r9, r6, r7
        fmul2   r10, r6, r7
        ffma2   r11, r6, r7, r6
        fmin2   r12, r6, -r7
        fmax2   r13, |r6|, r7
        iadd2   r14, r6, r1
        isub2   r15, r6, r1
        imul2   r16, r6, r1
        fcmp2.lt r17, r6, r7
        fcmp2.ge r18, r6, r7
        fcmp2.eq r19, r6, r6
        fcmp2.ne r20, r6, r7
        fadd2.hlo r21, r6, r7
        fadd2.hhi r22, r6, r7
        fmul2.hswap r23, r6, r7
        fadd2.sat r24, r6, r7
        unpackh.lo r25, r8
        unpackh.hi r26, r8
        swaph   r27, r8
        packh   r28, r25, r26
        ffma2.sat.hswap r29, r7, r6, r8
        end
