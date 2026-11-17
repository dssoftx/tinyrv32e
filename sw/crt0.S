/* Startup: clear registers, set up gp/sp, copy .data from flash to PSRAM,
 * clear .bss, run main. The register file has no reset (it would cost ~5%
 * area), so its power-up contents are undefined until cleared here. */
    .section .text.init
    .globl _start
_start:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15
    li      x\r, 0
    .endr
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top

    la      a0, __data_load
    la      a1, __data_start
    la      a2, __data_end
1:  bgeu    a1, a2, 2f
    lw      a3, 0(a0)
    sw      a3, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    j       1b

2:  la      a0, __bss_start
    la      a1, __bss_end
3:  bgeu    a0, a1, 4f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    j       3b

4:  call    main
5:  j       5b          /* main returned: spin (the testbench treats this as halt) */
