# mem.s: global lw/sw/sw.x, atomics (global and shared), fence, lds/sts,
# lwc and the c operands.  Every lane uses its own addresses (lidn).
        slli    r1, lidn, 2             # 4 x global lane index
        movi    r2, 0x8000
        add     r2, r2, r1              # this lane's word at 0x8000
        add     r3, lidn, one           # lane + 1 (one is fp 1.0 bits: a pattern)
        addi    r4, lidn, 100
        sw      r4, 0(r2)
        sw      r3, 256(r2)
        sw.x    r4, 512(r2)
        fence   0
        lw      r5, 0(r2)
        lw      r6, 256(r2)
        lw      r7, 512(r2)
        wait    0, 0, 0
        add     r8, r5, r6
        atom.add r9, (r2), r8           # old = lane + 100
        atom.xor r10, (r2), r3
        atom.smax r11, (r2), r4
        atom.umin r12, (r2), r3
        addi    r13, r4, 1
        atom.cmpxchg r14, (r2), r13, r12  # compare value r12 (rs3)
        atom.xchg r15, (r2), r1
        lw      r16, 0(r2)
        # shared memory: this lane's word in the workgroup's LDS
        sts     r4, 0(r1)
        sts     r3, 512(r1)
        lds     r17, 0(r1)
        lds     r18, 512(r1)
        atoms.add r19, (r1), r3
        atoms.or r20, (r1), r8
        atoms.cmpxchg r21, (r1), r1, r20
        lds     r22, 0(r1)
        # constant bank: lwc word index (rs1 + imm) & 255, and c operands
        andi    r23, lidn, 7
        lwc     r24, 3(r23)
        add     r25, c1, c31
        fence   7
        sw      r22, 768(r2)
        lw      r26, 768(r2)
        end
