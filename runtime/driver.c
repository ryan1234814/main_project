/* driver.c — bare-metal main() for the demos.
 * The kernel compiled from .aiir has ABI:
 *     void ai_kernel(const float *A, const float *B, float *OUT);
 * This demo is single-pass on purpose: this toolchain's main() restores
 * the caller's stack (it does not push/pop a frame), so any loop that
 * re-enters main would corrupt crt0.  Each demo prints its inputs, runs
 * the AI kernel, prints the result, and exits the simulator.
 */
#include <stdint.h>

extern void print_str(const char *);
extern void print_int(long);
extern void print_float(float);
extern void exit_sim(int) __attribute__((noreturn));

void ai_kernel(const float *a, const float *b, float *out);

/* Stock operands, used only by a kernel that supplies no override table.
 * Each demo1-8 .aiir now carries its own `; @operands:` line, so these are a
 * fallback.  Only the first 8 of the 16 lanes are printed (see main below),
 * i.e. unchanged these would show as
 *     A (operand) = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ]
 *     B (operand) = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]   (B = 2*Identity)  */
static float A[16] = {
    1, -2, 3, -4, 5, -6, 7, -8, 9, 10, 11, 12, 13, 14, 15, 16
};
static float B[16] = {
    2, 0, 0, 0,
    0, 2, 0, 0,
    0, 0, 2, 0,
    0, 0, 0, 2
};
static float OUT[16];

/* Optional per-demo operand override: a kernel (.s) may define the weak
 * table below as { 0x444F5031 "DOP1", count, .float values... }.  When
 * present, its values replace the default A/B before the kernel runs.
 * A kernel that does not provide it (the weak symbol stays null) keeps A/B
 * exactly as hardcoded above.
 * Slots 0..15 fill A, slots 16..31 fill B, so a demo may override one, the
 * other, or both.  The values each demo actually runs with are written in the
 * comments at the top of its .aiir, together with the exact A/B/OUT lines the
 * driver prints.                                                            */
extern const uint32_t demo_operands[] __attribute__((weak));

void main(void)
{
    if (demo_operands && demo_operands[0] == 0x444F5031u) {
        int cnt = (int)demo_operands[1];
        if (cnt > 32) cnt = 32;                       /* A[16] + B[16] */
        const float *vals = (const float *)(demo_operands + 2);
        for (int i = 0; i < cnt; i++)
            if (i < 16) A[i] = vals[i];
            else        B[i - 16] = vals[i];
    }

    print_str("== AISS demo ==\n");
    print_str("Two number lists go in (A and B); the AI kernel computes OUT.\n");
    print_str("A (operand) = [");
    for (int i = 0; i < 8; i++) { print_float(A[i]); print_str(" "); }
    print_str("]\n");
    print_str("B (operand) = [");
    for (int i = 0; i < 8; i++) { print_float(B[i]); print_str(" "); }
    print_str("]\n");
    print_str("Running ai_kernel(A, B, OUT) ...\n");

    ai_kernel(A, B, OUT);

    print_str("OUT (result) = [");
    for (int i = 0; i < 8; i++) { print_float(OUT[i]); print_str(" "); }
    print_str("]\n");
    print_str("done\n");
    exit_sim(0);
}
