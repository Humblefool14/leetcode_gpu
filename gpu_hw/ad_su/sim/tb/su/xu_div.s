# xu_div.s: the transcendental unit (rcp rsq exp2 log2 sin cos fsqrt) and the
# divider (div divu rem remu, with zero divisors and the overflow case).
        add     r1, lidn, zero
        addi    r2, r1, -16
        fcvt.s.w r3, r2                 # -16 .. 47
        movi    r4, 0x3e000000          # 0.125
        fmul.s  r5, r3, r4              # -2 .. 5.875
        rcp     r6, r5
        rsq     r7, |r5|
        exp2    r8, r5
        log2    r9, |r5|
        sin     r10, r5
        cos     r11, -r5
        fsqrt.s r12, |r5|
        fsqrt.s r13, r5, rtz            # NaN for negative lanes
        movi    r14, 0x80000000
        addi    r15, r2, 0              # -16 .. 47 (some zeros)
        sub     r16, r14, r1
        div     r17, r16, r15
        divu    r18, r16, r15
        rem     r19, r16, r15
        remu    r20, r16, r15
        addi    r21, zero, -1
        div     r22, r14, r21           # overflow: 0x80000000
        rem     r23, r14, r21           # 0
        div     r24, r1, zero           # -1
        remu    r25, r1, zero           # r1
        rcp     r26, zero               # +inf
        end
