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

void main(void)
{
    print_str("== AISS demo ==\n");
    print_str("A = [");
    for (int i = 0; i < 8; i++) { print_float(A[i]); print_str(" "); }
    print_str("]\n");
    print_str("B = [");
    for (int i = 0; i < 8; i++) { print_float(B[i]); print_str(" "); }
    print_str("]\n");

    ai_kernel(A, B, OUT);

    print_str("OUT = [");
    for (int i = 0; i < 8; i++) { print_float(OUT[i]); print_str(" "); }
    print_str("]\n");

    print_str("done\n");
    exit_sim(0);
}
