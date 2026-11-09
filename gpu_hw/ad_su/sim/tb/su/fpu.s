# fpu.s: the FPU: fadd/fsub/fmul with every rounding mode, the float
# modifiers (-x, |x|, -|x|), .sat, the R4 forms, fsgnj/fmin/fmax,
# conversions, comparisons, fround, fract and the integer multiplies.
        add     r1, lidn, zero
        addi    r1, r1, -20             # -20 .. 43
        fcvt.s.w r2, r1                 # float(lane - 20)
        movi    r3, 0x3eaaaaab          # 1/3
        fmul.s  r4, r2, r3              # (lane - 20) / 3
        fadd.s  r5, r4, r3, rne
        fadd.s  r6, r4, r3, rtz
        fsub.s  r7, r4, r3, rdn
        fsub.s  r8, r4, r3, rup
        fmul.s  r9, r4, r3, rmm
        fmul.s  r10, r4, r4, dyn
        fadd.s  r11, -r4, |r3|
        fmul.s  r12, -|r4|, r3
        fadd.s.sat r13, r4, half
        fmadd.s r14, r4, r3, r2
        fmsub.s r15, r4, -r3, r2, rtz
        fnmsub.s r16, |r4|, r3, r2
        fnmadd.s r17, r4, r3, -r2, rup
        fsgnj.s r18, r3, r4
        fmin.s  r19, r4, r2
        fmax.s  r20, r4, -r2
        fcvt.w.s r21, r4, rtz
        fcvt.wu.s r22, r4, rup
        fcvt.s.wu r23, r1, rdn
        feq.s   r24, r4, r2
        flt.s   r25, r4, r3
        fle.s   r26, r2, r4
        fne.s   r27, r4, r4
        fround.s r28, r4, rdn
        fround.s r29, r4, rtz
        fract   r30, r4
        mul     r31, r1, r1
        mulh    r0, r1, r23
        mulhsu  r1, r1, r23
        mulhu   r2, r23, r23
        fround.s r3, -r4, rup
        end
