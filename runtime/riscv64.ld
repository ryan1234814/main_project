/* riscv64.ld — linker script for the AISS bare-metal demos */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
}

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.*) } > RAM
  .data : {
    __global_pointer$ = . + 0x800;
    *(.sdata .sdata.*) *(.data .data.*)
  } > RAM
  .bss (NOLOAD) : {
    __bss_start = .;
    *(.sbss .sbss.*) *(.bss .bss.*)
    *(COMMON)
    __bss_end = .;
  } > RAM
  . = ALIGN(16);
  . = . + 0x4000;               /* 16 KiB stack */
  _stack_top = .;
}
