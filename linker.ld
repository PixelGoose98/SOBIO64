ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)


SECTIONS
{
. = 0x00100000; /* load the kernel physically at 1 MiB */


.start : {
*(.start)
}


.text : ALIGN(16) {
*(.text*)
}


.rodata : ALIGN(16) {
*(.rodata*)
}


.data : ALIGN(16) {
*(.data*)
*(.bss*) *(COMMON)
}
}
