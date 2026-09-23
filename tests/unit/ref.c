/* ref.c — INDEPENDENT host reference for the AISS unit tests.
 * Recomputes the expected OUT with plain C float math and prints it in the
 * EXACT same "d.ddd " token format as runtime/runtime.c print_float(), so the
 * test script can string-compare simulator output against this reference.
 *
 * Usage:
 *   ref add   <n>
 *   ref mul   <n>
 *   ref relu  <n>
 *   ref mm    <M> <K> <N>            (single matmul, A=MxK, B=KxN)
 *   ref relu_add_mul <n>             (chain: relu(A+B)*A)
 *   ref mm_mm <M> <K> <N>            (chain: (A@B)@B, square MxK=KxN)
 * A[] and B[] below MUST stay identical to tests/unit/unit_driver.c.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static float A[16] = {
    -2, 3, -0.0f, 5, 0, -6, 7, -8, 9, -1, 0, 2, -3, 4, -5, 6
};
static float B[16] = {
     2, -4, 6, 0, -1, 3, -7, 8, -9, 1, 0, -2, 5, -6, 7, -3
};

/* mirror of runtime.c print_float (fixed-point, truncating) */
static void pfloat(float f)
{
    long w  = (long)f;
    long fr = (long)((f - (float)w) * 1000.0f);
    if (fr < 0) fr = -fr;
    printf("%ld.%ld ", w, fr);
}

static void matmul(const float *a, const float *b, float *c, int M, int K, int N)
{
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            float acc = 0.f;
            for (int k = 0; k < K; k++) acc += a[i*K + k] * b[k*N + j];
            c[i*N + j] = acc;
        }
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: ref <op> ...\n"); return 2; }
    const char *op = argv[1];

    if (!strcmp(op, "add") || !strcmp(op, "mul") || !strcmp(op, "relu")) {
        int n = atoi(argv[2]);
        for (int i = 0; i < n; i++) {
            float v = !strcmp(op, "add") ? A[i] + B[i]
                    : !strcmp(op, "mul") ? A[i] * B[i]
                    : (A[i] > 0 ? A[i] : 0.0f);
            pfloat(v);
        }
    } else if (!strcmp(op, "mm")) {
        int M = atoi(argv[2]), K = atoi(argv[3]), N = atoi(argv[4]);
        float c[16]; matmul(A, B, c, M, K, N);
        for (int i = 0; i < M*N; i++) pfloat(c[i]);
    } else if (!strcmp(op, "relu_add_mul")) {
        int n = atoi(argv[2]);
        for (int i = 0; i < n; i++) {
            float s = A[i] + B[i];
            float r = s > 0 ? s : 0.0f;
            pfloat(r * A[i]);
        }
    } else if (!strcmp(op, "mm_mm")) {
        int M = atoi(argv[2]), K = atoi(argv[3]), N = atoi(argv[4]);
        float t[16], d[16];
        matmul(A, B, t, M, K, N);   /* t = A@B (MxN, here MxK so reuse as MxN) */
        matmul(t, B, d, M, N, N);   /* d = t@B (MxN) */
        for (int i = 0; i < M*N; i++) pfloat(d[i]);
    } else {
        fprintf(stderr, "ref: unknown op %s\n", op); return 2;
    }
    printf("\n");
    return 0;
}
