/* ============================================================================
 * rvss.c — RISC-V RV64IMAF chip simulator (ISS) + AISS custom AI unit
 * ============================================================================
 * Executes ELF binaries built by the riscv64-unknown-elf toolchain for the
 * demos in this project.  Implemented machine:
 *
 *   RV64I   : full base ISA (LUI/AUIPC/JAL/JALR, branches, all loads/stores,
 *             OP-IMM incl. 64-bit shifts, OP incl. M-extension, W-forms,
 *             FENCE, ECALL/EBREAK)
 *   RV64F/D : loads/stores, arithmetic, FMA, comparisons, conversions,
 *             sign-injection, FCLASS — with proper NaN-boxing for f32
 *   AISS    : custom-0 (opcode 0x0B, funct7 0x0A) AI instructions:
 *               ai.add  ai.mul  ai.relu  ai.matmul
 *             Register convention (set up by the compiler before each .word):
 *               x5=t0 count, x6=t1 srcA, x7=t2 srcB,
 *               x28=t3 dst, x29/x30/x31 = M/K/N for matmul
 *
 * Machine model: single hart, 8 MB RAM at 0x80000000, tohost semihosting
 * (write + exit) as described in runtime/runtime.c.
 *
 * Build:  make rvss
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <math.h>

#define RAM_BASE  0x80000000ULL
#define RAM_SIZE  (8u * 1024 * 1024)            /* 8 MB */
#define STACK_TOP (RAM_BASE + RAM_SIZE - 16)

static uint8_t *ram;
static uint64_t x[32];
static uint64_t f[32];   /* raw IEEE-754 bits: D full 64, S NaN-boxed low 32 */
static uint64_t pc;
static int      exited = 0;
static int      exit_code = 0;
static long     insn_count = 0;

/* last-256 instruction ring buffer, dumped on fatal errors */
static uint64_t trace_pc[256]; static uint32_t trace_in[256]; static int trace_n = 0;
static void trace_step(uint64_t p, uint32_t i) { trace_pc[trace_n] = p; trace_in[trace_n] = i; trace_n = (trace_n + 1) & 255; }
static void trace_dump(void) {
    fprintf(stderr, "--- last up-to-256 instructions ---\n");
    for (int k = 0; k < 256; k++) {
        int idx = (trace_n + k) & 255;
        if (!trace_in[idx]) continue;
        fprintf(stderr, "  0x%08llx: 0x%08x\n", (unsigned long long)trace_pc[idx], trace_in[idx]);
    }
}

/* ---------------- memory -------------------------------------------------- */
static inline uint64_t addr_of(uint64_t a) { return a - RAM_BASE; }
static int in_ram(uint64_t a) { return a >= RAM_BASE && a < RAM_BASE + RAM_SIZE; }

static uint64_t load(uint64_t a, int size) {
    if (!in_ram(a)) { fprintf(stderr, "rvss: load fault @0x%llx\n", (unsigned long long)a); trace_dump(); exit(2); }
    uint64_t p = addr_of(a); uint64_t v = 0;
    for (int i = size - 1; i >= 0; i--) v = (v << 8) | ram[p + i];
    return v;
}
static void store(uint64_t a, uint64_t v, int size) {
    if (!in_ram(a)) { fprintf(stderr, "rvss: store fault @0x%llx\n", (unsigned long long)a); trace_dump(); exit(2); }
    uint64_t p = addr_of(a);
    for (int i = 0; i < size; i++) ram[p + i] = (uint8_t)(v >> (8 * i));
}
/* debug watchpoint hook (silent by default) */
static void store_watch(uint64_t a, uint64_t v, int size) {
    if (getenv("RVSS_WATCH") && ((a >= 0x800044d0ULL && a < 0x80004508ULL) ||
                                 (a >= 0x800004a0ULL && a < 0x800004e0ULL)))
        fprintf(stderr, "WATCH store @0x%llx v=0x%llx size=%d pc=0x%llx\n",
                (unsigned long long)a, (unsigned long long)v, size, (unsigned long long)pc);
    store(a, v, size);
}

/* ---------------- AISS custom AI unit ------------------------------------ */
static void ai_vadd(uint64_t d, uint64_t a, uint64_t b, int n) {
    for (int i = 0; i < n; i++) {
        uint32_t va = (uint32_t)load(a + 4*i, 4), vb = (uint32_t)load(b + 4*i, 4);
        float fa, fb; memcpy(&fa, &va, 4); memcpy(&fb, &vb, 4);
        float r = fa + fb; uint32_t u; memcpy(&u, &r, 4);
        store(d + 4*i, u, 4);
    }
}
static void ai_vmul(uint64_t d, uint64_t a, uint64_t b, int n) {
    for (int i = 0; i < n; i++) {
        uint32_t va = (uint32_t)load(a + 4*i, 4), vb = (uint32_t)load(b + 4*i, 4);
        float fa, fb; memcpy(&fa, &va, 4); memcpy(&fb, &vb, 4);
        float r = fa * fb; uint32_t u; memcpy(&u, &r, 4);
        store(d + 4*i, u, 4);
    }
}
static void ai_vrelu(uint64_t d, uint64_t a, int n) {
    for (int i = 0; i < n; i++) {
        uint32_t va = (uint32_t)load(a + 4*i, 4);
        float fa; memcpy(&fa, &va, 4);
        float r = fa > 0 ? fa : 0.0f; uint32_t u; memcpy(&u, &r, 4);
        store(d + 4*i, u, 4);
    }
}
static void ai_matmul(uint64_t d, uint64_t a, uint64_t b, int M, int K, int N) {
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            float acc = 0.f;
            for (int k = 0; k < K; k++) {
                uint32_t ua = (uint32_t)load(a + 4*(i*K + k), 4);
                uint32_t ub = (uint32_t)load(b + 4*(k*N + j), 4);
                float fa, fb; memcpy(&fa, &ua, 4); memcpy(&fb, &ub, 4);
                acc += fa * fb;
            }
            uint32_t u; memcpy(&u, &acc, 4);
            store(d + 4*(i*N + j), u, 4);
        }
}

/* ---------------- ELF loader --------------------------------------------- */
static void load_elf(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); exit(1); }
    uint8_t hdr[64];
    if (fread(hdr, 1, 64, fp) != 64 || memcmp(hdr, "\x7f" "ELF", 4)) {
        fprintf(stderr, "rvss: %s: not an ELF file\n", path); exit(1);
    }
    uint64_t e_entry, e_phoff; uint16_t e_phnum, e_phentsize;
    memcpy(&e_entry, hdr + 24, 8);
    memcpy(&e_phoff, hdr + 32, 8);
    memcpy(&e_phentsize, hdr + 54, 2);
    memcpy(&e_phnum, hdr + 56, 2);
    for (int i = 0; i < e_phnum; i++) {
        uint8_t ph[56];
        fseek(fp, (long)(e_phoff + (uint64_t)i * e_phentsize), SEEK_SET);
        if (fread(ph, 1, 56, fp) != 56) break;
        uint32_t p_type; memcpy(&p_type, ph + 0, 4);
        if (p_type != 1 /*PT_LOAD*/) continue;
        uint64_t p_offset, p_vaddr, p_filesz;
        memcpy(&p_offset, ph + 8, 8);
        memcpy(&p_vaddr, ph + 16, 8);
        memcpy(&p_filesz, ph + 32, 8);
        if (!in_ram(p_vaddr)) continue;
        fseek(fp, (long)p_offset, SEEK_SET);
        if (p_vaddr - RAM_BASE + p_filesz > RAM_SIZE) {
            fprintf(stderr, "rvss: segment too large\n"); exit(1);
        }
        if (fread(ram + addr_of(p_vaddr), 1, p_filesz, fp) != p_filesz) {
            fprintf(stderr, "rvss: short read\n"); exit(1);
        }
    }
    pc = e_entry;
    fclose(fp);
}

/* minimal ELF symtab parse: find tohost */
typedef struct { char name[32]; uint64_t addr; } Sym;
static Sym syms[4096]; static int nsyms;
static uint64_t tohost_addr = 0;
static void load_syms(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return;
    uint8_t hdr[64];
    if (fread(hdr, 1, 64, fp) != 64) { fclose(fp); return; }
    uint64_t e_shoff; uint16_t e_shnum, e_shentsize;
    memcpy(&e_shoff, hdr + 40, 8);
    memcpy(&e_shentsize, hdr + 58, 2);
    memcpy(&e_shnum, hdr + 60, 2);
    if (!e_shoff || !e_shnum) { fclose(fp); return; }
    uint8_t *sh = malloc((size_t)e_shentsize * e_shnum);
    fseek(fp, (long)e_shoff, SEEK_SET);
    if (fread(sh, 1, (size_t)e_shentsize * e_shnum, fp) != (size_t)e_shentsize * e_shnum) { free(sh); fclose(fp); return; }
    uint64_t strtab_off = 0, strtab_sz = 0;
    for (int i = 0; i < e_shnum; i++) {
        const uint8_t *s = sh + (size_t)i * e_shentsize;
        uint32_t s_type; memcpy(&s_type, s + 4, 4);
        if (s_type == 3 && !strtab_off) {
            memcpy(&strtab_off, s + 24, 8); memcpy(&strtab_sz, s + 32, 8);
        }
    }
    if (!strtab_off || !strtab_sz) { free(sh); fclose(fp); return; }
    uint8_t *strtab = malloc(strtab_sz + 1);
    fseek(fp, (long)strtab_off, SEEK_SET);
    if (fread(strtab, 1, strtab_sz, fp) != strtab_sz) { free(strtab); free(sh); fclose(fp); return; }
    strtab[strtab_sz] = 0;
    for (int i = 0; i < e_shnum; i++) {
        const uint8_t *s = sh + (size_t)i * e_shentsize;
        uint32_t s_type; memcpy(&s_type, s + 4, 4);
        if (s_type != 2) continue;
        uint64_t off, sz, ent; memcpy(&off, s + 24, 8); memcpy(&sz, s + 32, 8); memcpy(&ent, s + 56, 8); /* sh_entsize @56 */
        if (!off || !sz || !ent) continue;
        fseek(fp, (long)off, SEEK_SET);
        uint8_t *tab = malloc((size_t)sz);
        if (fread(tab, 1, (size_t)sz, fp) != sz) { free(tab); break; }
        for (uint64_t o = 0; o + 24 <= sz; o += ent) {
            const uint8_t *e = tab + o;
            uint32_t name; memcpy(&name, e, 4);
            uint64_t val; memcpy(&val, e + 8, 8);
            if (name < strtab_sz && strtab[name] && nsyms < 4096) {
                strncpy(syms[nsyms].name, (const char *)strtab + name, 31);
                syms[nsyms].addr = val; nsyms++;
            }
        }
        free(tab);
    }
    free(strtab); free(sh); fclose(fp);
    for (int i = 0; i < nsyms; i++)
        if (!strcmp(syms[i].name, "tohost")) tohost_addr = syms[i].addr;
}

/* ---------------- tohost semihosting -------------------------------------- */
/* descriptor protocol (see runtime/runtime.c):
 *  [0] = 1 -> exit(0); [0] = 2 -> exit([1]); [0] = 3 -> write [1],[2]     */
static void do_tohost(void) {
    uint64_t v = load(tohost_addr, 8);
    if (v == 1) { exited = 1; exit_code = 0; return; }
    if (v == 2) { exited = 1; exit_code = (int)load(tohost_addr + 8, 8); return; }
    if (v == 0x03) {
        uint64_t buf = load(tohost_addr + 8, 8);
        uint64_t len = load(tohost_addr + 16, 8);
        if (!in_ram(buf) || buf + len > RAM_BASE + RAM_SIZE) {
            fprintf(stderr, "rvss: bad write buffer 0x%llx\n", (unsigned long long)buf);
            exit(2);
        }
        uint64_t p = addr_of(buf);
        for (uint64_t i = 0; i < len; i++) fputc(ram[p + i], stdout);
        fflush(stdout);
        store(tohost_addr, 0, 8);          /* consumed */
        return;
    }
    fprintf(stderr, "rvss: unknown tohost magic 0x%llx\n", (unsigned long long)v);
    exit(2);
}

/* ---------------- main interpreter loop ---------------------------------- */
/* FP registers hold raw IEEE-754 bit patterns: D = full 64 bits,
 * S = value in the low 32 bits, upper 32 set (NaN-boxed, RV64 F/D ABI). */
static double fget_d(int i) { double d; memcpy(&d, &f[i], 8); return d; }
static double fget_s(int i) { uint32_t lo = (uint32_t)f[i]; float s;
                              memcpy(&s, &lo, 4); return (double)s; }
/* NOTE: unlike x0, there is NO zero FP register — f0 is a real register. */
static void fset_d(int i, double d) { memcpy(&f[i], &d, 8); }
static void fset_s(int i, float s) {
    uint32_t u; memcpy(&u, &s, 4); f[i] = 0xFFFFFFFF00000000ULL | u; }

static uint64_t prev_ra;
static int sp_was_odd;
static uint64_t last_pc = 0xdeadbeef, last_insn;
static void step(void) {
    if (!in_ram(pc)) {
        fprintf(stderr, "rvss: pc out of range: 0x%llx\n", (unsigned long long)pc);
        trace_dump();
        for (int i = 0; i < 32; i += 4)
            fprintf(stderr, "  x%-2d=%016llx x%-2d=%016llx x%-2d=%016llx x%-2d=%016llx\n",
                    i,   (unsigned long long)x[i],   i+1, (unsigned long long)x[i+1],
                    i+2, (unsigned long long)x[i+2], i+3, (unsigned long long)x[i+3]);
        exit(2);
    }
    uint32_t I = (uint32_t)load(pc, 4);
    trace_step(pc, I);
    if ((x[2] & 1) && !sp_was_odd) {
        fprintf(stderr, "!!! sp became ODD (0x%llx) entering pc=0x%llx (last_insn @0x%llx = 0x%08x)\n",
                (unsigned long long)x[2], (unsigned long long)pc,
                (unsigned long long)last_pc, (unsigned)last_insn);
    }
    sp_was_odd = (x[2] & 1) != 0;
    if (x[1] != prev_ra) {
        if (x[1] == 0x3080000300ULL && prev_ra != 0x3080000300ULL)
            fprintf(stderr, "!!! ra became BAD entering pc=0x%llx (prev_ra=0x%llx, last_insn @0x%llx = 0x%08x)\n",
                    (unsigned long long)pc, (unsigned long long)prev_ra,
                    (unsigned long long)last_pc, (unsigned)last_insn);
        prev_ra = x[1];
    }
    last_pc = pc; last_insn = I;
    { static const char *brk; static int brk_on = -1;
      if (brk_on < 0) { brk = getenv("RVSS_BRK"); brk_on = brk ? 1 : 0; }
      if (brk_on && (uint64_t)strtoull(brk, 0, 0) == pc) {
        fprintf(stderr, "BRK @0x%llx:", (unsigned long long)pc);
        for (int r = 0; r < 32; r++) fprintf(stderr, " x%d=%llx", r, (unsigned long long)x[r]);
        for (int r = 0; r < 12; r++) fprintf(stderr, " f%d=%.3f", r, fget_s(r));
        fprintf(stderr, "\n");
      } }
    int op = I & 0x7F;
    int rd  = (I >> 7)  & 0x1F;
    int f3  = (I >> 12) & 0x7;
    int rs1 = (I >> 15) & 0x1F;
    int rs2 = (I >> 20) & 0x1F;
    int f7  = (I >> 25) & 0x7F;
    int64_t imm_i = (int64_t)(int32_t)I >> 20;
    /* S-type: imm[11:5]=I[31:25], imm[4:0]=I[11:7] (NOT rs2!) */
    int64_t imm_s = (((int64_t)(int32_t)I >> 20) & ~0x1FULL) | ((I >> 7) & 0x1F);
    int64_t imm_b = (((int64_t)(int32_t)I >> 31) << 12) |
                    (((I >> 7) & 1) << 11) | (((I >> 25) & 0x3F) << 5) |
                    (((I >> 8) & 0xF) << 1);
    int64_t imm_u = (int64_t)(int32_t)(I & 0xFFFFF000u);
    int64_t imm_j = (((int64_t)(int32_t)I >> 31) << 20) |
                    (((I >> 12) & 0xFF) << 12) | (((I >> 20) & 1) << 11) |
                    (((I >> 21) & 0x3FF) << 1);

    uint64_t npc = pc + 4;
    switch (op) {
    case 0x37: if (rd) x[rd] = (uint64_t)(uint32_t)imm_u; break;      /* lui: RV64 zero-extends the 32-bit result */
    case 0x17: if (rd) x[rd] = pc + imm_u; break;                     /* auipc*/
    case 0x6F: if (rd) x[rd] = pc + 4; npc = pc + imm_j; break;       /* jal  */
    case 0x67: { uint64_t t = (x[rs1] + imm_i) & ~1ULL;
                 if (rd) x[rd] = pc + 4; npc = t; } break;            /* jalr */
    case 0x63: {                                                      /* br   */
        int take = 0;
        switch (f3) {
        case 0: take = x[rs1] == x[rs2]; break;
        case 1: take = x[rs1] != x[rs2]; break;
        case 4: take = (int64_t)x[rs1] <  (int64_t)x[rs2]; break;
        case 5: take = (int64_t)x[rs1] >= (int64_t)x[rs2]; break;
        case 6: take = x[rs1] <  x[rs2]; break;
        case 7: take = x[rs1] >= x[rs2]; break;
        default: fprintf(stderr, "rvss: bad branch f3=%d\n", f3); exit(2); }
        if (take) npc = pc + imm_b; } break;
    case 0x03: { uint64_t a = x[rs1] + imm_i; uint64_t v;             /* load */
        switch (f3) {
        case 0: v = (uint64_t)(int64_t)(int8_t)load(a, 1); break;
        case 1: v = (uint64_t)(int64_t)(int16_t)load(a, 2); break;
        case 2: v = (uint64_t)(int64_t)(int32_t)load(a, 4); break;
        case 3: v = load(a, 8); break;
        case 4: v = load(a, 1); break;
        case 5: v = load(a, 2); break;
        case 6: v = load(a, 4); break;
        default: fprintf(stderr, "rvss: bad load f3=%d\n", f3); exit(2); }
        if (rd) x[rd] = v; } break;
    case 0x23: { uint64_t a = x[rs1] + imm_s;                         /* store */
        switch (f3) {
        case 0: store_watch(a, x[rs2], 1); break;
        case 1: store_watch(a, x[rs2], 2); break;
        case 2: store_watch(a, x[rs2], 4); break;
        case 3: store_watch(a, x[rs2], 8); break;
        default: fprintf(stderr, "rvss: bad store f3=%d\n", f3); exit(2); } } break;
    case 0x13: { int64_t a = (int64_t)x[rs1]; uint64_t v = 0;         /* op-imm */
        switch (f3) {
        case 0: v = (uint64_t)(a + imm_i); break;
        case 2: v = a < imm_i; break;
        case 3: v = x[rs1] < (uint64_t)imm_i; break;
        case 4: v = x[rs1] ^ imm_i; break;
        case 6: v = x[rs1] | imm_i; break;
        case 7: v = x[rs1] & imm_i; break;
        case 1: v = x[rs1] << ((I >> 20) & 0x3F); break;   /* SLLI: shamt is 6 bits */
        case 5: { int top6 = (I >> 26) & 0x3F;             /* bit25 is shamt[5] */
                int shamt = (I >> 20) & 0x3F;
                if (top6 == 0x00) v = x[rs1] >> shamt;
                else if (top6 == 0x10) v = (uint64_t)((int64_t)x[rs1] >> shamt);
                else { fprintf(stderr, "rvss: bad imm shift f7=0x%x @0x%llx insn 0x%08x\n", f7, (unsigned long long)pc, I); exit(2); } } break; }
        if (rd) x[rd] = v; } break;
    case 0x33: { uint64_t a = x[rs1], b = x[rs2], v = 0;              /* R-op  */
        if (f7 == 1) {                                                /* RV64M */
            int64_t sa = (int64_t)a, sb = (int64_t)b;
            switch (f3) {
            case 0: v = (uint64_t)(sa * sb); break;
            case 1: v = (uint64_t)(((unsigned __int128)((uint64_t)sa * (uint64_t)sb)) >> 64); break;
            case 2: v = (uint64_t)(((unsigned __int128)((uint64_t)sa * (uint64_t)b)) >> 64); break;
            case 3: v = (uint64_t)(((unsigned __int128)a * (unsigned __int128)b) >> 64); break;
            case 4: v = sb ? (uint64_t)(sa / sb) : (uint64_t)-1; break;
            case 5: v = b ? a / b : (uint64_t)-1; break;
            case 6: v = sb ? (uint64_t)(sa % sb) : (uint64_t)a; break;
            case 7: v = b ? a % b : a; break; }
        } else {
            switch (f3) {
            case 0: v = (f7 & 0x20) ? a - b : a + b; break;
            case 1: v = (uint64_t)((int64_t)a << (b & 63)); break;
            case 2: v = (int64_t)a < (int64_t)b; break;
            case 3: v = a < b; break;
            case 4: v = a ^ b; break;
            case 5: v = (f7 & 0x20) ? (uint64_t)((int64_t)a >> (b & 63)) : a >> (b & 63); break;
            case 6: v = a | b; break;
            case 7: v = a & b; break; }
        }
        if (rd) x[rd] = v; } break;
    case 0x1B: { int64_t a = (int64_t)x[rs1]; uint64_t v = 0;         /* op-imm-32 */
        switch (f3) {
        case 0: v = (uint64_t)(int64_t)(int32_t)(a + imm_i); break;
        case 1: v = (uint64_t)(int64_t)(int32_t)((int32_t)x[rs1] << (rs2 & 31)); break;
        case 5: if (f7 == 0x00) v = (uint64_t)(int64_t)(int32_t)((uint32_t)x[rs1] >> (rs2 & 31));
                else v = (uint64_t)(int64_t)(int32_t)((int32_t)x[rs1] >> (rs2 & 31)); break;
        default: fprintf(stderr, "rvss: bad opimm32 f3=%d\n", f3); exit(2); }
        if (rd) x[rd] = v; } break;
    case 0x3B: { uint64_t a = x[rs1], b = x[rs2], v = 0;              /* op-32  */
        if (f7 == 1) {
            int64_t sa = (int64_t)(int32_t)a, sb = (int64_t)(int32_t)b;
            switch (f3) {
            case 0: v = (uint64_t)(int64_t)(int32_t)(sa * sb); break;
            case 4: v = sb ? (uint64_t)(int64_t)(int32_t)(sa / sb) : (uint64_t)-1; break;
            case 5: v = b ? (uint32_t)((uint32_t)a / (uint32_t)b) : (uint64_t)-1; break;
            case 6: v = sb ? (uint64_t)(int64_t)(int32_t)(sa % sb) : sa; break;
            case 7: v = b ? (uint32_t)((uint32_t)a % (uint32_t)b) : (uint32_t)a; break;
            default: fprintf(stderr, "rvss: bad mulw f3=%d\n", f3); exit(2); }
        } else {
            switch (f3) {
            case 0: v = (uint64_t)(int64_t)(int32_t)((f7 & 0x20) ? (int32_t)a - (int32_t)b : (int32_t)a + (int32_t)b); break;
            case 1: v = (uint64_t)(int64_t)(int32_t)((int32_t)a << (b & 31)); break;
            case 5: v = (f7 & 0x20) ? (uint64_t)(int64_t)(int32_t)((int32_t)a >> (b & 31))
                                    : (uint64_t)(int32_t)((uint32_t)a >> (b & 31)); break;
            default: fprintf(stderr, "rvss: bad op32 f3=%d f7=0x%x\n", f3, f7); exit(2); }
        }
        if (rd) x[rd] = v; } break;
    case 0x0F: break;                                                 /* fence */
    case 0x73:                                                        /* sys   */
        if (f3 == 0 && (I >> 20) == 0) {                             /* ecall */
            if (tohost_addr) {
                uint64_t cmd = load(tohost_addr, 8);
                if (cmd) do_tohost();
            } else { exited = 1; exit_code = (int)x[17] & 0xFF; }
        } else if (f3 == 0 && (I >> 20) == 1) { exited = 1; exit_code = 3; } /* ebreak */
        break;
    case 0x07: { uint64_t a = x[rs1] + imm_i;                         /* fld/flw */
        if (f3 == 3) f[rd] = load(a, 8);                             /* D: raw bits */
        else         f[rd] = 0xFFFFFFFF00000000ULL | (uint32_t)load(a, 4);
        } break;
    case 0x27: { uint64_t a = x[rs1] + imm_s;                         /* fsd/fsw */
        if (f3 == 3) store_watch(a, f[rs2], 8);
        else         store_watch(a, (uint32_t)f[rs2], 4);
        } break;
    case 0x43: case 0x47: case 0x4B: case 0x4F: {                     /* FMA: fmadd/fmsub/fnmsub/fnmadd */
        int dp = f7 & 1;
        double a = dp ? fget_d(rs1) : fget_s(rs1);
        double b = dp ? fget_d((I >> 27) & 0x1F) : fget_s((I >> 27) & 0x1F);
        double c = dp ? fget_d(rs2)   : fget_s(rs2);
        double r = (op == 0x43) ? a * c + b :
                   (op == 0x47) ? a * c - b :
                   (op == 0x4B) ? -(a * c) + b : -(a * c) - b;
        if (getenv("RVSS_FMA"))
            fprintf(stderr, "FMA op=%02llx rd=f%d a=%.3f b=%.3f c=%.3f -> %.3f @0x%llx\n",
                    (unsigned long long)op, rd, a, b, c, r, (unsigned long long)pc);
        if (dp) fset_d(rd, r); else fset_s(rd, (float)r);
        } break;
    case 0x53: {                                                      /* FP    */
        /* funct7 bit0 = fmt (0=S, 1=D); f3 = RM for arith/cvt,
         * f3 = op select for FSGNJ/FMINMAX/FCMP/FMV/FCLASS          */
        int dp = f7 & 1;
        double a = dp ? fget_d(rs1) : fget_s(rs1);
        double b = dp ? fget_d(rs2) : fget_s(rs2);
        double c = dp ? fget_d((I >> 27) & 0x1F)
                      : fget_s((I >> 27) & 0x1F);      /* FMA rs3    */
        double r = a;
        uint64_t xi = 0;
        int write_x = 0;
        switch (f7) {
        case 0x00: case 0x01: r = a + b; break;                       /* FADD  */
        case 0x04: case 0x05: r = a - b; break;                       /* FSUB  */
        case 0x08: case 0x09: r = a * b; break;                       /* FMUL  */
        case 0x0C: case 0x0D: r = b != 0 ? a / b
                                : (a == 0 ? NAN : (a > 0 ? INFINITY : -INFINITY)); break;
        case 0x2C: case 0x2D: r = a >= 0 ? sqrt(a) : NAN; break;      /* FSQRT */
        case 0x10: case 0x11: /* FSGNJ / FSGNJN / FSGNJX (f3 select)  */
            if      (f3 == 2) r = (signbit(a) ^ signbit(b)) ? -fabs(a) : fabs(a);
            else if (f3 == 1) r = signbit(b) ? fabs(a) : -fabs(a);
            else              r = signbit(b) ? -fabs(a) : fabs(a);
            if (getenv("RVSS_FMA"))
                fprintf(stderr, "SGNJ f7=%02x rd=f%d rs1=f%d a=%.3f rs2=f%d b=%.3f -> %.3f @0x%llx\n",
                        f7, rd, rs1, a, rs2, b, r, (unsigned long long)pc);
            break;
        case 0x14: case 0x15: /* FMIN (f3=0) / FMAX (f3=1)            */
            if (a != a)      r = b;
            else if (b != b) r = a;
            else if (f3 == 0) r = a < b ? a : b;
            else              r = a > b ? a : b;
            break;
        case 0x40: case 0x41: r = a * c + b; break;                   /* FMADD  */
        case 0x44: case 0x45: r = a * c - b; break;                   /* FMSUB  */
        case 0x48: case 0x49: r = -(a * c) + b; break;                /* FNMSUB */
        case 0x4C: case 0x4D: r = -(a * c) - b; break;                /* FNMADD */
        case 0x50: case 0x51: /* FCMP: f3 0=FLE 1=FLT 2=FEQ           */
            write_x = 1;
            xi = (f3 == 2) ? (a == b) : (f3 == 1) ? (a < b) : (a <= b);
            break;
        case 0x60: case 0x61: { /* FCVT.W/WU/L/LU.[SD]: fp -> int    */
            write_x = 1;
            int64_t v64;
            switch (rs2) {
            case 0:  v64 = (int64_t)(int32_t)a; break;
            case 1:  v64 = (int64_t)(uint32_t)a; break;
            case 2:  v64 = (int64_t)a; break;
            default: v64 = (int64_t)(uint64_t)a; break; }
            xi = (uint64_t)v64; } break;
        case 0x68: case 0x69: { /* FCVT.S/D.W/WU/L/LU: int(rs1) -> fp   */
            switch (rs2) {
            case 0:  r = (int32_t)x[rs1]; break;
            case 1:  r = (uint32_t)x[rs1]; break;
            case 2:  r = (int64_t)x[rs1]; break;
            default: r = (uint64_t)x[rs1]; break; } } break;
        case 0x20: r = dp ? (double)(float)a : a; break;              /* FCVT.S.D */
        case 0x21: r = dp ? a : (double)(float)a; break;              /* FCVT.D.S */
        case 0x70: case 0x71: /* FMV.X.W/D (f3=0) / FCLASS (f3=1)      */
            write_x = 1;
            if (f3 == 0) {
                xi = dp ? f[rs1] : (uint32_t)f[rs1];
            } else {
                xi = 0;
                if (a != a) xi = 1 << 8;
                else if (a == 0) xi = signbit(a) ? (1 << 2) : (1 << 3);
                else if (a == INFINITY) xi = 1 << 7;
                else if (a == -INFINITY) xi = 1 << 0;
                else if (a < 0) xi = 1 << 1;
                else xi = 1 << 6;
            }
            break;
        case 0x78: /* FMV.W.X: int bits -> fp reg (NaN-boxed); f0 is REAL */
            f[rd] = 0xFFFFFFFF00000000ULL | (uint32_t)x[rs1];
            goto fp_done;
        case 0x79: /* FMV.D.X */
            f[rd] = x[rs1];
            goto fp_done;
        default:
            fprintf(stderr, "rvss: unimplemented FP f7=0x%02x f3=%d @0x%llx\n",
                    f7, f3, (unsigned long long)pc);
            trace_dump(); exit(2); }
        if (write_x) { if (rd) x[rd] = xi; }
        else if (dp) fset_d(rd, r);
        else fset_s(rd, (float)r);
fp_done:;
        } break;
    case 0x0B: {                                                      /* AISS! */
        if (f7 != 0x0A) {
            fprintf(stderr, "rvss: unknown custom-0 f7=0x%02x @0x%llx\n", f7, (unsigned long long)pc);
            trace_dump(); exit(2);
        }
        uint64_t dst = x[28], srcA = x[6];
        switch (f3) {
        case 0: ai_vadd(dst, srcA, x[7], (int)x[5]); break;   /* ai.add  */
        case 1: ai_vrelu(dst, srcA, (int)x[5]); break;        /* ai.relu */
        case 2: ai_vmul(dst, srcA, x[7], (int)x[5]); break;   /* ai.mul  */
        case 3: ai_matmul(dst, srcA, x[7], (int)x[29], (int)x[30], (int)x[31]); break;
        default: fprintf(stderr, "rvss: unknown AISS funct3=%d\n", f3); trace_dump(); exit(2); }
        } break;
    default:
        fprintf(stderr, "rvss: illegal insn 0x%08x op=0x%02x @0x%llx\n",
                I, op, (unsigned long long)pc);
        trace_dump(); exit(2);
    }
    x[0] = 0;
    pc = npc;
    insn_count++;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: rvss <elf>\n"); return 1; }
    ram = calloc(1, RAM_SIZE);
    if (!ram) { fprintf(stderr, "rvss: out of memory\n"); return 1; }
    load_elf(argv[1]);
    load_syms(argv[1]);
    x[2] = STACK_TOP;                 /* sp */
    x[3] = RAM_BASE;                  /* gp */

    long maxinsns = getenv("RVSS_MAX") ? atol(getenv("RVSS_MAX")) : 500000000L;
    for (long i = 0; i < maxinsns && !exited; i++) {
        step();
        if (tohost_addr) {
            uint64_t cmd = load(tohost_addr, 8);
            if (cmd) do_tohost();          /* poll after every insn */
        }
    }
    if (getenv("RVSS_TRACE")) trace_dump();
    fprintf(stderr, "\n[rvss] retired %ld instructions, exit=%d\n", insn_count, exit_code);
    return exit_code;
}
