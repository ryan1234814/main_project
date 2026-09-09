/* crt0.s — bare-metal startup for the RV64IMAF+AISS simulator */
    .section .text.init
    .globl _start
_start:
    la      gp, __global_pointer$
    la      sp, _stack_top
    call    main
1:  wfi
    j       1b
    .size _start, .-_start
