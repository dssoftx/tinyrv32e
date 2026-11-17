/* riscv-tests environment for tinyrv32e (no CSRs, no traps).
 * Pass: GPIO_OUT = 0x01.  Fail: GPIO_OUT = 0x80 | failing test number.
 * .data is copied to PSRAM at startup, exactly like the C runtime does. */
#ifndef _ENV_TINYRV32E_H
#define _ENV_TINYRV32E_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U
#define TESTNUM gp

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  2;                                                      \
        .globl  _start;                                                 \
_start:                                                                 \
        li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;  li x5, 0;           \
        li x6, 0;  li x7, 0;  li x8, 0;  li x9, 0;  li x10, 0;          \
        li x11, 0; li x12, 0; li x13, 0; li x14, 0; li x15, 0;          \
        la      a0, __data_load;                                        \
        la      a1, __data_start;                                       \
        la      a2, __data_end;                                         \
100:    bgeu    a1, a2, 101f;                                           \
        lw      a3, 0(a0);                                              \
        sw      a3, 0(a1);                                              \
        addi    a0, a0, 4;                                              \
        addi    a1, a1, 4;                                              \
        j       100b;                                                   \
101:    li      TESTNUM, 0;

#define RVTEST_CODE_END

#define RVTEST_PASS                                                     \
        li      t0, 0x80000000;                                         \
        li      t1, 1;                                                  \
        sb      t1, 0(t0);                                              \
102:    j       102b;

#define RVTEST_FAIL                                                     \
        li      t0, 0x80000000;                                         \
        andi    t1, TESTNUM, 0x7f;                                      \
        ori     t1, t1, 0x80;                                           \
        sb      t1, 0(t0);                                              \
103:    j       103b;

#define EXTRA_DATA
#define EXTRA_INIT
#define EXTRA_INIT_TIMER

#define RVTEST_DATA_BEGIN                                               \
        EXTRA_DATA                                                      \
        .data;                                                          \
        .align 4;                                                       \
        .global begin_signature;                                        \
begin_signature:

#define RVTEST_DATA_END                                                 \
        .align 4;                                                       \
        .global end_signature;                                          \
end_signature:

#endif
