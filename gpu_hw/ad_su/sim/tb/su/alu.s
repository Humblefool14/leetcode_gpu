# alu.s: every ALU operation (R and I forms, lui/movi, sel) on lane-varying
# values; ends with `end`.  Run: gsi1model.py alu.s --lanes 64 -o alu.exp
        add     r1, lane, zero          # r1 = lane
        add     r2, lidn, warp          # r2 = 32 warp + lane + warp
        movi    r3, 0x89abcdef
        movi    r4, -7
        lui     r5, 0xfffff             # 0xfffff000
        mul     r6, r1, r3              # lane-varying pattern (mul on the FPU unit)
        xor     r6, r6, r2
        add     r7, r6, r3
        sub     r8, r6, r3
        sll     r9, r6, r1
        slt     r10, r6, r4
        sltu    r11, r6, r3
        xor     r12, r6, r3
        srl     r13, r6, r2
        sra     r14, r3, r1
        or      r15, r6, r5
        and     r16, r6, r3
        min     r17, r6, r4
        max     r18, r6, r4
        minu    r19, r6, r3
        maxu    r20, r6, r3
        andn    r21, r6, r3
        orn     r22, r6, r3
        xnor    r23, r6, r3
        addi    r24, r6, -2048
        slti    r25, r6, 1000
        sltiu   r26, r1, 17
        xori    r27, r6, -1
        ori     r28, r6, 0x7f0
        andi    r29, r6, 0x3c
        slli    r30, r6, 13
        srli    r31, r6, 7
        srai    r0, r3, 31
        sel     r1, r6, r3, r4          # (a & b) | (~a & c)
        addi    r2, r2, 0x12345         # imm_hi in word1
        add     r3, c0, r2              # constant-bank operand (c0 = data word 0)
        add     r4, one, onei           # specials
        add     r5, mone, wgx
        end
