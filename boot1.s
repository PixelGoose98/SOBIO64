BITS 16
ORG 0x7C00
%ifndef LOADER_SECTORS
%define LOADER_SECTORS 4   ; fallback if not passed from Makefile
%endif
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    ; enable A20
    in al, 0x92
    or al, 0000_0010b
    out 0x92, al

    ; read stage2 to 0x8000
    lea si, [dap_stage2]
    mov byte [si], 0x10
    mov byte [si+1], 0x00
    mov word [si+2], LOADER_SECTORS
    mov word [si+4], 0x8000
    mov word [si+6], 0x0000
    mov dword [si+8], 1
    mov dword [si+12], 0

    mov si, dap_stage2
    mov ah, 0x42
    int 0x13
    jc bootfail

    jmp 0x0000:0x8000

bootfail:
    cli
.hang: hlt
    jmp .hang

align 4
dap_stage2: times 16 db 0

times 510-($-$$) db 0
dw 0xAA55
