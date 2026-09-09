/* ============================================================================
 * ai-compiler.c — minimal AI-dialect compiler -> RISC-V RV64IMAF assembly
 * ============================================================================
 * Input : MLIR-flavoured .aiir  (see the demos directory)
 * Output: RISC-V assembly implementing
 *             void ai_kernel(const float *A, const float *B, float *OUT);
 *
 * AI ops   : ai.add, ai.mul, ai.relu, ai.matmul
 *   -O0    : lowered to plain RV64IMAF scalar loops (flw/fadd.s/fsw, fmadd.s)
 *   -O1    : lowered to custom-0 AISS instructions (.word); see
 *              the docs directory for the encoding spec
 * Basic ops: arith.constant / arith.addf / arith.mulf (scalar f32)
 *
 * Kernel ABI: a0 = A, a1 = B, a2 = OUT.  Intermediate tensors live in
 * stack slots (sp - 16 - 64*(t-2)); scalar temps at sp - 1024 - 4*t.
 * AISS register convention: x5 = count/M?, x6 = srcA, x7 = srcB, x28 = dst,
 * matmul dims: x29 = M, x30 = K, x31 = N.
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdint.h>
#include <stdarg.h>

#define MAX_LINES 256
#define MAX_LEN   512
#define MAX_T     64            /* temps                                */
#define SLOT_TEN  64            /* bytes per tensor slot (16 floats)    */

static char src[MAX_LINES][MAX_LEN];
static int  nlines = 0;
static int  emit_hw = 0;
static FILE *out;

static void die(const char *msg, int line) {
    fprintf(stderr, "ai-compiler: error: %s (line %d)\n", msg, line + 1);
    exit(1);
}
static void emit(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(out, fmt, ap); va_end(ap);
    fputc('\n', out);
}

/* ---------------- AISS custom-0 encodings -------------------------------- */
/* R-type: funct7=0x0A | rs2 | rs1 | funct3 | rd | opcode=0x0B              */
static uint32_t ai_enc(int f3, int rd, int rs1, int rs2) {
    return (0x0Au << 25) | ((uint32_t)rs2 << 20) | ((uint32_t)rs1 << 15) |
           ((uint32_t)f3 << 12) | ((uint32_t)rd << 7) | 0x0B;
}

/* ---------------- small helpers ------------------------------------------ */
static void rstrip_comments(char *s) {
    char *c = strchr(s, ';'); if (c) *c = 0;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
}
static int temp_of(char **p, int line) {
    while (**p && **p != '%') (*p)++;
    if (!**p) die("expected %temp", line);
    (*p)++;
    int v = (int)strtol(*p, (char **)p, 10);
    if (v < 0 || v >= MAX_T) die("temp out of range", line);
    return v;
}
static int tensor_slot(int t)  { return 16 + SLOT_TEN * (t - 2); }  /* sp-off */
static int scalar_slot(int t)  { return 1024 + 4 * t; }             /* sp-off */

/* parse "tensor<a x b x f32>" after `from`; dims[] gets up to 2 numbers */
static int parse_dims(const char *from, int *dims) {
    const char *ty = strstr(from, "tensor<");
    if (!ty) return 0;
    ty += 7;
    int nd = 0;
    while (*ty && *ty != '>' && nd < 2) {
        if (isdigit((unsigned char)*ty)) dims[nd++] = (int)strtol(ty, (char **)&ty, 10);
        else ty++;
    }
    return nd;
}

/* ---------------- lowering ---------------------------------------------- */
/* src pointer for temp t: a0/a1 for inputs, else stack slot */
static void emit_src(int t, const char *into, int line) {
    if (t == 0)      emit("        mv      %s, a0", into);
    else if (t == 1) emit("        mv      %s, a1", into);
    else             emit("        addi    %s, sp, -%d", into, tensor_slot(t));
    (void)line;
}

/* software elementwise: op ∈ {add, mul, relu} */
static void sw_elementwise(const char *op, int d, int a, int b, int n, int line) {
    if (n > 16) die("tensor > 16 elements (demo limit)", line);
    emit("        li      t0, %d                      # n", n);
    emit_src(a, "t1", line);
    if (b >= 0) emit_src(b, "t2", line);
    emit("        addi    t3, sp, -%d                 # dst %%d", tensor_slot(d), d);
    emit(".Lsw%d_%d:", line, d);
    emit("        flw     fa0, 0(t1)");
    if (strcmp(op, "relu") == 0) {
        emit("        fmv.w.x ft3, x0                    # 0.0f");
        emit("        flt.s   t4, fa0, ft3               # a < 0 ?");
        emit("        beq     t4, x0, 1f");
        emit("        fmv.s   fa1, ft3");
        emit("        j       2f");
        emit("1:      fmv.s   fa1, fa0");
        emit("2:      fsw     fa1, 0(t3)");
    } else {
        emit("        flw     fa1, 0(t2)");
        emit("        %s  fa2, fa0, fa1", strcmp(op, "add") == 0 ? "fadd.s" : "fmul.s");
        emit("        fsw     fa2, 0(t3)");
    }
    emit("        addi    t1, t1, 4");
    if (b >= 0) emit("        addi    t2, t2, 4");
    emit("        addi    t3, t3, 4");
    emit("        addi    t0, t0, -1");
    emit("        bnez    t0, .Lsw%d_%d", line, d);
}

/* hardware elementwise via AISS custom-0 */
static void hw_elementwise(int f3, const char *name, int d, int a, int b, int n, int line) {
    if (n > 32) die("tensor > 32 elements (AISS VLEN limit)", line);
    emit("        li      t0, %d                      # VLEN", n);
    emit_src(a, "t1", line);
    if (b >= 0) emit_src(b, "t2", line);
    emit("        addi    t3, sp, -%d                 # dst %%d", tensor_slot(d), d);
    emit("        .word   0x%08x                # %s t3, t1%s len=%d",
         ai_enc(f3, 28, 6, b >= 0 ? 7 : 0), name, b >= 0 ? ", t2" : "", n);
}

/* software matmul MxK * KxN */
static void sw_matmul(int d, int a, int b, int M, int N, int K, int line) {
    if (M * N > 16 || K > 16) die("matmul > 4x4 (demo limit)", line);
    emit_src(a, "a3", line);                 /* A */
    emit_src(b, "a4", line);                 /* B */
    emit("        addi    a5, sp, -%d                 # C %%d", tensor_slot(d), d);
    emit("        li      t0, %d                      # M", M);
    emit("        li      t1, %d                      # N", N);
    emit("        li      t2, %d                      # K", K);
    emit("        addi    a6, x0, 0                   # i");
    emit(".Lmm_i%d:", line);
    emit("        bge     a6, t0, .Lmm_end%d", line);
    emit("        addi    a7, x0, 0                   # j");
    emit(".Lmm_j%d:", line);
    emit("        bge     a7, t1, .Lmm_ni%d", line);
    emit("        fmv.w.x ft0, x0                     # acc = 0");
    emit("        addi    t4, x0, 0                   # k");
    emit(".Lmm_k%d:", line);
    emit("        bge     t4, t2, .Lmm_st%d", line);
    emit("        mul     t5, a6, t2");
    emit("        add     t5, t5, t4");
    emit("        slli    t5, t5, 2");
    emit("        add     t5, a3, t5");
    emit("        flw     fa0, 0(t5)");
    emit("        mul     t5, t4, t1");
    emit("        add     t5, t5, a7");
    emit("        slli    t5, t5, 2");
    emit("        add     t5, a4, t5");
    emit("        flw     fa1, 0(t5)");
    emit("        fmadd.s ft1, fa0, fa1, ft0");   /* ft1 = A*B + acc      */
    emit("        fmv.s   ft0, ft1");              /* acc = ft1            */
    emit("        addi    t4, t4, 1");
    emit("        j       .Lmm_k%d", line);
    emit(".Lmm_st%d:", line);
    emit("        mul     t5, a6, t1");
    emit("        add     t5, t5, a7");
    emit("        slli    t5, t5, 2");
    emit("        add     t5, a5, t5");
    emit("        fsw     ft0, 0(t5)");
    emit("        addi    a7, a7, 1");
    emit("        j       .Lmm_j%d", line);
    emit(".Lmm_ni%d:", line);
    emit("        addi    a6, a6, 1");
    emit("        j       .Lmm_i%d", line);
    emit(".Lmm_end%d:", line);
}

/* hardware matmul via AISS custom-0 macro-op */
static void hw_matmul(int d, int a, int b, int M, int N, int K, int line) {
    if (M * N > 16 || K > 16) die("matmul > 4x4 (demo limit)", line);
    emit("        li      t4, %d                      # M", M);
    emit("        li      t5, %d                      # K", K);
    emit("        li      t6, %d                      # N", N);
    emit_src(a, "t1", line);
    emit_src(b, "t2", line);
    emit("        addi    t3, sp, -%d                 # C %%d", tensor_slot(d), d);
    emit("        .word   0x%08x                # ai.matmul t3, t1, t2, %dx%dx%d",
         ai_enc(3, 28, 6, 7), M, K, N);
}

/* copy returned tensor to OUT pointer (a2) */
static void emit_return(int t, int n, int line) {
    if (n <= 0) n = 16;
    if (t == 0)      emit("        mv      t1, a0");
    else if (t == 1) emit("        mv      t1, a1");
    else             emit("        addi    t1, sp, -%d", tensor_slot(t));
    emit("        mv      t2, a2                      # OUT");
    emit("        li      t0, %d", n);
    emit(".Lret%d:", line);
    emit("        flw     fa0, 0(t1)");
    emit("        fsw     fa0, 0(t2)");
    emit("        addi    t1, t1, 4");
    emit("        addi    t2, t2, 4");
    emit("        addi    t0, t0, -1");
    emit("        bnez    t0, .Lret%d", line);
    emit("        ret");
}

/* ---------------- main ---------------------------------------------------- */
int main(int argc, char **argv) {
    const char *inpath = NULL, *outpath = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) outpath = argv[++i];
        else if (!strcmp(argv[i], "-O1")) emit_hw = 1;
        else if (!strcmp(argv[i], "-O0")) emit_hw = 0;
        else inpath = argv[i];
    }
    if (!inpath || !outpath) {
        fprintf(stderr, "usage: ai-compiler [-O0|-O1] -o out.s in.aiir\n");
        return 1;
    }
    FILE *in = fopen(inpath, "r");
    if (!in) { perror(inpath); return 1; }
    char buf[MAX_LEN];
    while (nlines < MAX_LINES && fgets(buf, sizeof buf, in)) {
        rstrip_comments(buf);
        char *p = buf; while (isspace((unsigned char)*p)) p++;
        if (!*p) continue;
        strncpy(src[nlines++], p, MAX_LEN - 1);
    }
    fclose(in);

    out = fopen(outpath, "w");
    if (!out) { perror(outpath); return 1; }

    emit("# Generated by ai-compiler from %s (%s lowering)",
         inpath, emit_hw ? "AISS custom-0 hardware" : "RV64IMAF software");
    emit("        .option norvc");
    emit("        .text");
    emit("        .align  2");
    emit("        .globl  ai_kernel");
    emit("ai_kernel:");

    int ret_temp = -1, ret_n = 0;

    for (int i = 0; i < nlines; i++) {
        char *L = src[i];
        if (strstr(L, "ai.func") || strstr(L, "ai.entry") ||
            !strcmp(L, "}") || !strncmp(L, "}", 1))
            continue;

        /* ai.return %r : tensor<...> */
        if (!strncmp(L, "ai.return", 9)) {
            char *p = L;
            ret_temp = temp_of(&p, i);
            int dims[2] = {0, 0};
            if (parse_dims(p, dims) == 1) ret_n = dims[0];
            else ret_n = 16;
            continue;
        }

        /* AI op: %d = "ai.name"(%a[, %b]) : types */
        if (L[0] == '%' && strstr(L, "\"ai.")) {
            char *p = L;
            int d = temp_of(&p, i);
            char *q = strstr(L, "\"ai.") + 4;
            char name[16]; int k = 0;
            while (*q && *q != '"' && k < 15) name[k++] = *q++;
            name[k] = 0;

            char *pa = strchr(L, '(');
            if (!pa) die("missing operand list", i);
            int a = -1, b = -1;
            a = temp_of(&pa, i);
            if (strchr(pa, '%')) b = temp_of(&pa, i);

            int is_mm = !strcmp(name, "matmul");
            int dims[2] = {0, 0}, n = 8, M = 4, N = 4, K = 4;
            char *arrow = strstr(L, "->");
            if (is_mm) {
                if (parse_dims(L, dims) >= 2) { K = dims[1]; }        /* 1st operand: MxK */
                if (arrow && parse_dims(arrow, dims) >= 2) { M = dims[0]; N = dims[1]; }
            } else if (arrow && parse_dims(arrow, dims) == 1) {
                n = dims[0];
            }

            if (!strcmp(name, "add") || !strcmp(name, "mul") || !strcmp(name, "relu")) {
                int f3 = !strcmp(name, "add") ? 0 : !strcmp(name, "relu") ? 1 : 2;
                if (emit_hw) hw_elementwise(f3, name, d, a, b, n, i);
                else sw_elementwise(name, d, a, b, n, i);
            } else if (is_mm) {
                if (emit_hw) hw_matmul(d, a, b, M, N, K, i);
                else         sw_matmul(d, a, b, M, N, K, i);
            } else die("unknown ai op", i);
            continue;
        }

        /* basic scalar ops (arith dialect) */
        if (L[0] == '%' && strstr(L, "arith.constant")) {
            char *p = L;
            int d = temp_of(&p, i);
            const char *num = strstr(L, "constant") + 8;
            float fv = (float)strtod(num, NULL);
            uint32_t bits; memcpy(&bits, &fv, 4);
            emit("        li      t0, 0x%08x", bits);
            emit("        sw      t0, -%d(sp)                 # const %g", scalar_slot(d), (double)fv);
            emit("        flw     fa0, -%d(sp)", scalar_slot(d));
            emit("        fsw     fa0, -%d(sp)", scalar_slot(d));
            continue;
        }
        if (L[0] == '%' && (strstr(L, "arith.addf") || strstr(L, "arith.mulf"))) {
            char *p = L;
            int d = temp_of(&p, i);
            int a = temp_of(&p, i);
            int b = temp_of(&p, i);
            emit("        flw     fa0, -%d(sp)", scalar_slot(a));
            emit("        flw     fa1, -%d(sp)", scalar_slot(b));
            emit("        %s   fa2, fa0, fa1", strstr(L, "addf") ? "fadd.s" : "fmul.s");
            emit("        fsw     fa2, -%d(sp)", scalar_slot(d));
            continue;
        }
    }

    if (ret_temp < 0) die("no ai.return found", 0);
    emit_return(ret_temp, ret_n, nlines);
    emit("        .size   ai_kernel, .-ai_kernel");
    fclose(out);
    printf("ai-compiler: %s -> %s (%s lowering)\n",
           inpath, outpath, emit_hw ? "AISS hardware" : "RV64IMAF software");
    return 0;
}
