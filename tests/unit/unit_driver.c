/* unit_driver.c — bare-metal driver for ONE-op / chain unit tests.
 * It feeds fixed A/B arrays (covering 0, negative, positive, -0.0) to the
 * generated ai_kernel and prints the OPERANDS (A, B) and the RESULT (OUT),
 * all 16 words each, in the same d.ddd format the demos use.  Printing the
 * operands means a plain `./rvss <elf>` run shows the inputs, the operation
 * (chosen by which ELF) and the output together.  tests/unit/run-unit.sh
 * slices only the meaningful prefix per case, so extra trailing entries never
 * affect a comparison.  The A[]/B[] literals here are mirrored EXACTLY by
 * tests/unit/ref.c.
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
    print_str("== AISS unit test (beginner view) ==\n");
    print_str("We test one AI operation at a time. It shows the inputs and the answer.\n");
    print_str("Input A (16 numbers) = [");
    for (int i = 0; i < 16; i++) { print_float(A[i]); print_str(" "); }
    print_str("]\n");
    print_str("Input B (16 numbers) = [");
    for (int i = 0; i < 16; i++) { print_float(B[i]); print_str(" "); }
    print_str("]\n");
    print_str("Running the AI operation (ai.add / ai.mul / ai.relu / ai.matmul) ...\n");
    ai_kernel(A, B, OUT);
    print_str("Result OUT (16 numbers) = [");
    for (int i = 0; i < 16; i++) { print_float(OUT[i]); print_str(" "); }
    print_str("]\n");
    print_str("Meaning: For ai.add OUT[i]=A[i]+B[i], for ai.mul OUT[i]=A[i]*B[i], for ai.relu OUT[i]=max(0,A[i]), for ai.matmul OUT=A@B matrix multiply.\n");
    print_str("done - compare OUT with expected numbers\n");
    exit_sim(0);
}
