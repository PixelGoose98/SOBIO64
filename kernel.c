// kernel.c — tiny 64-bit freestanding kernel
// VGA text mode printing with working cursor and \n support

#include <stdint.h>

#define VGA_TEXT ((volatile uint16_t*)0xB8000)
#define VGA_COLS 80
#define VGA_ROWS 25
#define ARRAY_IDT_LEN 256

struct IntDesc64 {
   uint16_t offset_1;        // offset bits 0..15
   uint16_t selector;        // a code segment selector in GDT or LDT
   uint8_t  ist;             // bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
   uint8_t  type_attributes; // gate type, dpl, and p fields
   uint16_t offset_2;        // offset bits 16..31
   uint32_t offset_3;        // offset bits 32..63
   uint32_t zero;            // reserved
};

IntDesc64 array_int_desc_64[ARRAY_IDT_LEN];

struct IDTR {
    uint16_t limit;            
    uint64_t base;             
} __attribute__((packed));

static int cursor_x = 0;
static int cursor_y = 0;
static uint8_t text_color = 0x0F; // white on black

// I/O port helpers
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ __volatile__("outb %0,%1" : : "a"(val), "Nd"(port));
}

// Update the hardware cursor
static void update_cursor(void) {
    uint16_t pos = cursor_y * VGA_COLS + cursor_x;
    outb(0x3D4, 0x0F);
    outb(0x3D5, (uint8_t)(pos & 0xFF));
    outb(0x3D4, 0x0E);
    outb(0x3D5, (uint8_t)((pos >> 8) & 0xFF));
}

// Clear screen
static void clear_screen(void) {
    for (int y = 0; y < VGA_ROWS; ++y) {
        for (int x = 0; x < VGA_COLS; ++x) {
            VGA_TEXT[y * VGA_COLS + x] = (uint16_t)text_color << 8 | ' ';
        }
    }
    cursor_x = cursor_y = 0;
    update_cursor();
}

// Put a single character
static void putc(char c) {
    if (c == '\n') {
        cursor_x = 0;
        cursor_y++;
    } else {
        VGA_TEXT[cursor_y * VGA_COLS + cursor_x] =
            (uint16_t)text_color << 8 | (uint8_t)c;
        cursor_x++;
        if (cursor_x >= VGA_COLS) {
            cursor_x = 0;
            cursor_y++;
        }
    }

    // Scroll if needed
    if (cursor_y >= VGA_ROWS) {
        // Move everything up by one row
        for (int y = 1; y < VGA_ROWS; ++y) {
            for (int x = 0; x < VGA_COLS; ++x) {
                VGA_TEXT[(y - 1) * VGA_COLS + x] =
                    VGA_TEXT[y * VGA_COLS + x];
            }
        }
        // Clear last row
        for (int x = 0; x < VGA_COLS; ++x) {
            VGA_TEXT[(VGA_ROWS - 1) * VGA_COLS + x] =
                (uint16_t)text_color << 8 | ' ';
        }
        cursor_y = VGA_ROWS - 1;
    }

    update_cursor();
}

// Print a string
static void puts(const char* s) {
    for (int i = 0; s[i]; ++i) {
        putc(s[i]);
    }
}

void kmain(void) {
    clear_screen();

    puts("Hello from 64-bit kernel (no GRUB)!\n");
    puts("Now with working cursor + newlines :)");

    // Hang
    for(;;) __asm__ __volatile__("hlt");
}

// Minimal entry stub so the linker puts _start at the beginning
__attribute__((naked, section(".start"))) void _start(void) {
    __asm__ __volatile__(
        "cli\n\t"
        "xor %%rbp, %%rbp\n\t"
        "mov $0x200000, %%rsp\n\t" // stack at 2 MiB
        "call kmain\n\t"
        "hlt\n\t"
        : : : "memory"
    );
}
