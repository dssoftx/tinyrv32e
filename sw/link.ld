/* tinyrv32e: code + rodata in SPI flash, data/bss/stack in SPI PSRAM. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 16M
  RAM   (rwx) : ORIGIN = 0x01000000, LENGTH = 8M
}

SECTIONS
{
  .text : {
    KEEP(*(.text.init))
    *(.text .text.*)
  } > FLASH

  .rodata : ALIGN(4) {
    *(.rodata .rodata.* .srodata .srodata.*)
  } > FLASH

  .data : ALIGN(4) {
    __data_start = .;
    *(.data .data.* .sdata .sdata.*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM AT > FLASH
  __data_load = LOADADDR(.data);

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.bss .bss.* .sbss .sbss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > RAM

  __global_pointer$ = __data_start + 0x800;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
