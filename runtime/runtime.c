/* runtime.c — bare-metal print/exit for the AISS demos.
 * Simple tohost descriptor protocol understood by rvss:
 *   tohost[0] = 1                      -> exit(0)
 *   tohost[0] = (code << 1) | 1        -> exit(code)
 *   tohost[0] = 0x03 (SYS_WRITE)
 *   tohost[1] = buffer pointer (RAM vaddr)
 *   tohost[2] = length in bytes        -> write, then rvss clears tohost[0]
 */
#include <stdint.h>

volatile uint64_t tohost[4]   __attribute__((aligned(64)));
volatile uint64_t fromhost[4] __attribute__((aligned(64)));

#define SYS_WRITE 0x03
#define SYS_EXIT  0x02

void print_str(const char *s)
{
    uint64_t len = 0;
    while (s[len]) len++;
    tohost[1] = (uint64_t)(uintptr_t)s;
    tohost[2] = len;
    tohost[0] = SYS_WRITE;
    while (tohost[0]) { }              /* rvss clears it when done */
}

void print_int(long v)
{
    char buf[24];
    int neg = v < 0;
    unsigned long u = neg ? (unsigned long)(-(v + 1)) + 1 : (unsigned long)v;
    int i = 22; buf[23] = 0;
    do { buf[i--] = '0' + (u % 10); u /= 10; } while (u);
    if (neg) buf[i--] = '-';
    print_str(&buf[i + 1]);
}

void print_float(float f)              /* fixed-point d.ddd print */
{
    long whole = (long)f;
    long frac  = (long)((f - (float)whole) * 1000.0f);
    if (frac < 0) frac = -frac;
    print_int(whole); print_str("."); print_int(frac);
}

void exit_sim(int code)
{
    tohost[1] = (uint64_t)code;
    tohost[0] = SYS_EXIT;              /* rvss: exit(code) */
    for (;;) { }                       /* rvss sees exit and stops */
}
