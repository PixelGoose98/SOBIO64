# Two-stage bootloader Makefile (boot1.s, boot2.s, kernel.c) -> os.img
# Usage:
#   make        # builds os.img
#   make run    # runs os.img in qemu
#   make clean

SHELL := /bin/bash

# Tool detection (prefer cross tools)
CC      := $(shell command -v x86_64-elf-gcc 2>/dev/null || command -v gcc)
LD      := $(shell command -v x86_64-elf-ld 2>/dev/null || command -v ld)
OBJCOPY := $(shell command -v x86_64-elf-objcopy 2>/dev/null || command -v objcopy)
NASM    := $(shell command -v nasm 2>/dev/null || echo nasm)
QEMU    := $(shell command -v qemu-system-x86_64 2>/dev/null || echo qemu-system-x86_64)

CFLAGS  := -ffreestanding -m64 -mno-red-zone -fno-pic -O2 -Wall -Wextra -nostdlib -fno-stack-protector
LDFLAGS := -nostdlib -z max-page-size=0x1000 -T linker.ld

.PHONY: all run clean

all: os.img

# ----- Kernel build -----
kernel.o: kernel.c
	$(CC) $(CFLAGS) -c kernel.c -o kernel.o

kernel.elf: kernel.o linker.ld
	$(LD) $(LDFLAGS) kernel.o -o kernel.elf

kernel.bin: kernel.elf
	$(OBJCOPY) -O binary kernel.elf kernel.bin

# ----- Boot stage2 (initial assemble + reassemble with correct defines) -----
# First assemble boot2.s to get its size (it must assemble without defines using fallbacks)
boot2.tmp.bin: boot2.s
	$(NASM) -f bin boot2.s -o boot2.tmp.bin

# Reassemble boot2 with LOADER_SECTORS and KERNEL_SECTORS baked in
boot2_fixed.bin: boot2.tmp.bin kernel.bin boot2.s
	@boot2_bytes=$$(stat -c%s boot2.tmp.bin); \
	boot2_sectors=$$(( (boot2_bytes + 511) / 512 )); \
	kernel_bytes=$$(stat -c%s kernel.bin); \
	kernel_sectors=$$(( (kernel_bytes + 511) / 512 )); \
	echo "[i] boot2.tmp.bin = $$boot2_bytes bytes ($$boot2_sectors sectors)"; \
	echo "[i] kernel.bin = $$kernel_bytes bytes ($$kernel_sectors sectors)"; \
	$(NASM) -f bin -DLOADER_SECTORS=$$boot2_sectors -DKERNEL_SECTORS=$$kernel_sectors boot2.s -o boot2_fixed.bin

# ----- Boot stage1 (assemble with LOADER_SECTORS) -----
boot1.bin: boot1.s boot2_fixed.bin
	@boot2_bytes=$$(stat -c%s boot2_fixed.bin); \
	boot2_sectors=$$(( (boot2_bytes + 511) / 512 )); \
	echo "[i] Assembling boot1.s with LOADER_SECTORS=$$boot2_sectors"; \
	$(NASM) -f bin -DLOADER_SECTORS=$$boot2_sectors boot1.s -o boot1.bin

# ----- Build final disk image -----
os.img: boot1.bin boot2_fixed.bin kernel.bin
	@kernel_bytes=$$(stat -c%s kernel.bin); \
	kernel_sectors=$$(( (kernel_bytes + 511) / 512 )); \
	echo "[i] Creating os.img — kernel: $$kernel_bytes bytes ($$kernel_sectors sectors)"; \
	cat boot1.bin boot2_fixed.bin kernel.bin > os.img; \
	echo "[i] os.img created (size: $$(stat -c%s os.img) bytes)"

# ----- QEMU run -----
run: os.img
	$(QEMU) -drive format=raw,file=os.img -no-reboot -monitor stdio

# ----- Cleanup -----
clean:
	rm -f *.o *.elf *.bin *.tmp.bin os.img
