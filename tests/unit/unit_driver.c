/* unit_driver.c — bare-metal driver for ONE-op / chain unit tests.
 * It feeds fixed A/B arrays (covering 0, negative, positive, -0.0) to the
 * generated ai_kernel and prints the OPERANDS and the RESULT once each, using
 * the SAME labels as the demo driver (runtime/driver.c):
 *     A (operand) = [...]
 *     B (operand) = [...]
 *     OUT (result) = [...]
 * so `tests/unit/show.sh`, `tests/unit/run-unit.sh` and a plain `./rvss <elf>`
 * all read the same clean, single-pass output.  run-unit.sh slices only the
 * meaningful prefix per case, so extra trailing entries never affect a
 * comparison.  The A[]/B[] literals here are mirrored EXACTLY by ref.c.
 */
#include <stdint.h>

extern void print_str(const char *);
extern void print_float(float);
extern void exit_sim(int) __attribute__((noreturn));

void ai_kernel(const float *a, const float *b, float *out);

static float A[16] = {
    -2, 3, -0.0f, 5, 0, -6, 7, -8, 9, -1, 0, 2, -3, 4, -5, 6
};
static float B[16] = {
     2, -4, 6, 0, -1, 3, -7, 8, -9, 1, 0, -2, 5, -6, 7, -3
};
static float OUT[16];

void main(void)
{
    print_str("== AISS unit ==\n");
    print_str("A (operand) = [");
    for (int i = 0; i < 16; i++) { print_float(A[i]); print_str(" "); }
    print_str("]\n");
    print_str("B (operand) = [");
    for (int i = 0; i < 16; i++) { print_float(B[i]); print_str(" "); }
    print_str("]\n");
    print_str("Running ai_kernel(A, B, OUT) ...\n");
    ai_kernel(A, B, OUT);
    print_str("OUT (result) = [");
    for (int i = 0; i < 16; i++) { print_float(OUT[i]); print_str(" "); }
    print_str("]\n");
    print_str("done\n");
    exit_sim(0);
}
