; boot2.s  -- Stage 2 loader (assembled as a flat binary, ORG 0x8000)
; - Expects to be loaded by stage1 at 0000:0x8000
; - Reads kernel from disk at LBA = LOADER_START_LBA + LOADER_SECTORS
; - Loads kernel to physical 0x00100000 and enters x86_64 long mode
; - Safe mode: first read kernel to 0x00009000, copy to 0x00100000 in protected mode
;
; Usage: nasm -f bin -DLOADER_SECTORS=<n> -DKERNEL_SECTORS=<m> boot2.s -o boot2.bin

BITS 16
ORG 0x8000

%ifndef LOADER_SECTORS
%define LOADER_SECTORS 4     ; fallback if not provided by Makefile
%endif

%ifndef KERNEL_SECTORS
%define KERNEL_SECTORS 64    ; fallback if not provided by Makefile
%endif

%define LOADER_START_LBA 1
%define KERNEL_LOAD_PHYS 0x00100000   ; final destination (1 MiB)
%define KERNEL_TEMP_PHYS 0x00020000   ; safer temp place (128 KiB) to avoid overlap with boot2

stage2_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000


    ; --- VGA debug: write 'S' at top-left (real mode) ---
    push ax
    mov ax, 0xB800
    mov es, ax
    mov byte [es:0x0], 'S'
    mov byte [es:0x1], 0x07
    pop ax

    ; Build Disk Address Packet (DAP) for kernel read (INT 13h AH=0x42)
    ; We request BIOS to read kernel into physical 0x00009000 (segment:offset -> segment=0x0900, offset=0)
    lea si, [dap_kernel]
    mov byte  [si+0], 0x10                      ; DAP size
    mov byte  [si+1], 0x00                      ; reserved
    mov word  [si+2], KERNEL_SECTORS            ; number of sectors to read
    mov word  [si+4], 0x0000    ; offset 0
    mov word  [si+6], 0x2000    ; segment 0x2000 -> 0x2000:0x0000 = physical 0x20000
                   ; segment = 0x0900 -> 0x0900:0x0000 = phys 0x9000
    mov dword [si+8], LOADER_START_LBA + LOADER_SECTORS ; LBA low dword
    mov dword [si+12], 0                         ; LBA high dword

    ; Perform the extended read (AH=0x42) -> reads kernel into physical 0x00009000
    mov si, dap_kernel
    mov ah, 0x42
    int 0x13
    jc read_fail                ; carry => read failed

    ; --- VGA debug: write 'R' (read OK) ---
    push ax
    mov ax, 0xB800
    mov es, ax
    mov byte [es:2], 'R'
    mov byte [es:3], 0x07
    pop ax

    ; Prepare GDT and then switch to protected mode to perform the safe copy
    lgdt [gdt_descriptor]

    ; Enter Protected Mode (set CR0.PE=1)
    mov eax, cr0
    or  eax, 1
    mov cr0, eax
    jmp 0x08:protected_entry      ; far jump to 32-bit code selector (0x08)

; ---------------- 32-bit protected mode ----------------
BITS 32
protected_entry:
    ; set data segments (selector 0x10)
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x90000

    ; --- Copy kernel from KERNEL_TEMP_PHYS -> KERNEL_LOAD_PHYS ---
    ; We are still without paging; linear==physical, so we can copy directly.
    mov esi, KERNEL_TEMP_PHYS     ; source physical address (low)
    mov edi, KERNEL_LOAD_PHYS     ; dest physical address (1 MiB)
    mov ecx, KERNEL_SECTORS
    shl ecx, 9                    ; sectors * 512 = bytes
    cld
    rep movsb                     ; copies ECX bytes from [DS:ESI] -> [ES:EDI]; DS==ES==0x10 -> base 0

    ; --- VGA debug: write 'C' (copy done) at VGA offset 2 chars over ---
    mov byte [0x000B8000], 'C'
    mov byte [0x000B8001], 0x07

    ; Now proceed to set up page tables and enable long mode.

    ; Load CR3 with PML4 physical base (pml4 is located in this binary; since loaded at 0x8000 the label resolves correctly)
    lea eax, [pml4]
    mov cr3, eax

    ; Enable PAE
    mov eax, cr4
    or  eax, (1 << 5)    ; CR4.PAE
    mov cr4, eax

    ; Enable LME in IA32_EFER MSR (0xC0000080)
    mov ecx, 0xC0000080
    rdmsr                ; returns EDX:EAX
    or  eax, (1 << 8)    ; set LME bit
    wrmsr

    ; Enable paging by setting CR0.PG (bit 31)
    mov eax, cr0
    or  eax, (1 << 31)
    mov cr0, eax

    ; Far jump to 64-bit code selector to enter long mode
    jmp 0x18:long_mode_entry

; ---------------- 64-bit long mode ----------------
BITS 64
long_mode_entry:
    ; load 64-bit data selectors into segment registers (ignored but set for completeness)
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Jump to kernel physical entry point (1 MiB)
    mov rax, KERNEL_LOAD_PHYS
    jmp rax

; ---------------- error handling ----------------
read_fail:
    cli
.read_halt:
    hlt
    jmp .read_halt

; ---------------- Data: DAPs etc ----------------
align 16
dap_kernel: times 16 db 0

; ---------------- GDT (aligned) ----------------
align 8
gdt:
    dq 0x0000000000000000              ; null descriptor
    dq 0x00CF9A000000FFFF              ; 0x08: 32-bit code segment
    dq 0x00CF92000000FFFF              ; 0x10: 32-bit data segment
    dq 0x00AF9A0000000000              ; 0x18: 64-bit code segment (L bit controlled by EFER.LME)
    dq 0x00AF920000000000              ; 0x20: 64-bit data segment

gdt_descriptor:
    dw gdt_end - gdt - 1
    dd gdt
gdt_end:

; ---------------- Page tables (identity map 0..1GiB using 2 MiB pages)
ALIGN 4096
pml4:
    dq pdpt + 0x003       ; PML4 entry -> PDPT base + flags (present+rw)
    times 511 dq 0

ALIGN 4096
pdpt:
    dq pde0 + 0x003       ; PDPT entry -> PDE base + flags
    times 511 dq 0

ALIGN 4096
pde0:
%assign i 0
%rep 512                 ; create 512 PDEs * 2 MiB = 1 GiB
    dq (i * 0x200000) + 0x083   ; physical base + flags (present | write | PS)
%assign i i+1
%endrep

; ---------------- end of file ----------------
