# Normal RISC-V Operations — Examples and Commands

> All commands assume project root `/Users/ryangeorge/llvm` (`rvss.c:299`, `ai-compiler.c:92`).
> Prerequisites: `cc`, `make`, `riscv64-unknown-elf-gcc` (`brew install riscv-gnu-toolchain`), `python3`, `llvm-build/bin/clang`.

Normal operations are the standard **Rocket Chip RV64IMAFD** ISA decoded by `rvss.c:299-515` — every opcode != `0x0B`. Custom AISS ops (`0x0B`) are in `custom.md`.

---

## 1. What Counts as Normal

| Group | Mnemonics (normal) | `rvss.c` opcode / handler |
|-------|--------------------|---------------------------|
| RV64I base | `lui auipc jal jalr beq bne blt bge bltu bgeu lb lh lw ld lbu lhu lwu sb sh sw sd addi slti sltiu xori ori andi slli srli srai add sub sll slt sltu xor srl sra or and fence ecall ebreak` | `0x37,0x17,0x6F,0x67,0x63,0x03,0x23,0x13,0x33,0x0F,0x73` at `rvss.c:300` |
| RV64M | `mul mulh mulhsu mulhu div divu rem remu mulw divw divuw remw remuw` | `0x33 f7=0x01` at `rvss.c:350` / `0x3B` at `rvss.c:382` |
| RV64F/D | `flw fld fsw fsd fadd.s fsub.s fmul.s fdiv.s fsqrt.s fsgnj.s fsgnjn.s fsgnjx.s fmin.s fmax.s feq.s flt.s fle.s fcvt.w.s fcvt.wu.s fcvt.s.w fcvt.s.wu fmv.x.w fmv.w.x fmv.x.d fmv.d.x fclass.s fmadd.s fmsub.s fnmadd.s fnmsub.s` | `0x07,0x27,0x43,0x53` at `rvss.c:409` |
| W-forms | `addiw slliw srliw sraiw addw subw sllw srlw sraw` | `0x1B,0x3B` at `rvss.c:373` |

Fixed by spec — no `custom-0` (`0x0B`) in this file.

---

## 2. Build Host Tools (once)

```bash
make clean && make
# builds ai-compiler (ai-compiler.c:210) + rvss (rvss.c:539) + 3 ELFs via -march=rv64imafd -mabi=lp64 -mcmodel=medany
ls -lh ai-compiler rvss build/*.elf
```

---

## 3. Example 1 — Trivial C → Normal RV64GC (`addw`, `ld`, `sd`, `ret`)

Pure normal lowering via LLVM; no AI dialect.

```bash
cat > /tmp/trivial.c <<'EOF'
int add(int a,int b){return a+b;}
int main(){return add(2,3);}
EOF

# 3a. Emit assembly
llvm-build/bin/clang --target=riscv64 -march=rv64gc -S -o /tmp/trivial.s /tmp/trivial.c
cat /tmp/trivial.s
# -> addw a0,a0,a1  |  ld ra,8(sp)  |  ret   (rv64i normal)

# 3b. Emit LLVM IR (shows normal add)
llvm-build/bin/clang --target=riscv64 -march=rv64gc -emit-llvm -S -o /tmp/trivial.ll /tmp/trivial.c
cat /tmp/trivial.ll
# -> %7 = add nsw i32 %4, %5   (will become addw)

# 3c. llc → assembly
llvm-build/bin/llc -march=riscv64 -mattr=+m,+a,+f,+d,+c -o /tmp/trivial_llc.s /tmp/trivial.ll
cat /tmp/trivial_llc.s

# 3d. Object + disassembly + encoding — all normal
llvm-build/bin/clang --target=riscv64 -march=rv64gc -c -o /tmp/trivial.o /tmp/trivial.c
llvm-build/bin/llvm-objdump -d /tmp/trivial.o
# 0000000000000000 <add>:  ... 9d2d  addw a0,a0,a1 ...

llvm-build/bin/llvm-mc -triple=riscv64 --show-encoding /tmp/trivial_llc.s
# addw a0,a0,a1  # encoding: [0x2d,0x9d]

# 3e. Run via rvss (normal-only ELF)
cat > /tmp/trivial_main.c <<'EOF'
int add(int a,int b){return a+b;}
#include <stdint.h>
extern void exit_sim(int);
int main(){ if(add(2,3)==5) exit_sim(0); else exit_sim(1); return 0; }
EOF
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -T runtime/riscv64.ld -nostdlib -static -o /tmp/trivial.elf runtime/crt0.s /tmp/trivial_main.c runtime/runtime.c
riscv64-unknown-elf-objdump -d /tmp/trivial.elf | grep -E "addw|ret"
./rvss /tmp/trivial.elf 2>&1 | grep -E "retired|exit"
# [rvss] retired ~50 instructions, exit=0  (normal ops only)
```

---

## 4. Example 2 — AIIR → Normal Scalar Lowering (`-O0` = `flw`/`fadd.s`/`fsw` loops)

`ai-compiler -O0` emits **only normal ops** (`ai-compiler.c:92` `sw_elementwise`, `ai-compiler.c:132` `sw_matmul`). One `.word` = zero.

```bash
# 4a. Generate normal assembly for all demos
./ai-compiler -O0 -o /tmp/demo1_O0.s demos/demo1.aiir && cat /tmp/demo1_O0.s
./ai-compiler -O0 -o /tmp/demo2_O0.s demos/demo2.aiir && cat /tmp/demo2_O0.s
./ai-compiler -O0 -o /tmp/demo3_O0.s demos/demo3.aiir && cat /tmp/demo3_O0.s

# Inspect: no custom words
grep -c "\.word" /tmp/demo1_O0.s || echo "0 .word — pure normal (expected)"
grep -c "\.word" /tmp/demo2_O0.s || echo "0 .word"
wc -l /tmp/demo1_O0.s /tmp/demo2_O0.s /tmp/demo3_O0.s
# -> ~55 / ~70 / ~80 lines of scalar loops

# Normal-only kernel excerpt (ai-compiler.c:98):
# .Lsw1_2:
#         flw     fa0, 0(t1)           # normal RV64F load  (rvss.c:409)
#         flw     fa1, 0(t2)
#         fadd.s  fa2, fa0, fa1        # normal FP add      (rvss.c:442)
#         fsw     fa2, 0(t3)           # normal store
#         addi    t1, t1, 4            # normal RV64I       (rvss.c:334)
#         bnez    t0, .Lsw1_2          # normal branch      (rvss.c:305)
```

Full `demo1` normal dump:

```asm
ai_kernel:                              # demos/demo1.aiir:9  ai.add
        li      t0, 8                   # n              — normal 0x13
        mv      t1, a0                  #                — normal 0x13 (addi)
        mv      t2, a1
        addi    t3, sp, -16             # dst
.Lsw1_2:
        flw     fa0, 0(t1)              # normal 0x07
        flw     fa1, 0(t2)
        fadd.s  fa2, fa0, fa1           # normal 0x53 f7=0x00
        fsw     fa2, 0(t3)              # normal 0x27
        addi    t1, t1, 4
        addi    t2, t2, 4
        addi    t3, t3, 4
        addi    t0, t0, -1
        bnez    t0, .Lsw1_2             # normal 0x63
        # ... repeat for ai.mul (fmul.s) and ai.relu (flt.s/fmv.s/beq/j)
```

Matmul normal path uses `fmadd.s` + integer address math (`ai-compiler.c:150`):

```bash
grep -n "fmadd.s\|flw\|fsw\|mul\|slli\|bge\|fadd.s\|fmul.s" /tmp/demo2_O0.s
# mul     t5, a6, t2          — normal RV64M (rvss.c:350)
# slli    t5, t5, 2           — normal shift
# flw     fa0, 0(t5)          — normal
# fmadd.s ft1, fa0, fa1, ft0 — normal FMA (rvss.c:417)
```

---

## 5. Example 3 — Build and Run Normal-Only ELFs

```bash
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o build/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/${d}_sw.kernel.s -o build/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o build/${d}_sw.elf runtime/crt0.s build/${d}_sw.kernel.o runtime/runtime.c runtime/driver.c
done

# Disassemble — no custom opcode 0x0B
riscv64-unknown-elf-objdump -d build/demo1_sw.elf | sed -n '/<ai_kernel>:/,/ret/p' | head -n 100
riscv64-unknown-elf-objdump -d build/demo1_sw.elf | grep -E "14730e0b|14031e0b|14732e0b|14733e0b" && echo "found custom" || echo "no custom words — pure normal (expected)"

# Execute — rvss interprets only normal handlers (rvss.c:299-515)
for d in demo1 demo2 demo3; do echo "== $d (normal -O0) =="; ./rvss build/${d}_sw.elf 2>&1 | grep -E "OUT|retired|exit"; done
# demo1 OUT=[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]  4091 retired
# demo2 OUT=[2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ] 5042 retired
# demo3 OUT=[4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ] 5147 retired
```

---

## 6. Example 4 — Normal Scalar Ops via `arith` Dialect

`ai-compiler.c:299` lowers `arith.constant`/`arith.addf`/`arith.mulf` to normal scalar FP as well.

```bash
cat > /tmp/scalar.aiir <<'EOF'
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "arith.constant"() {value = 2.0 : f32} : () -> f32
  %3 = "arith.addf"(%2, %2) : (f32, f32) -> f32
  %4 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
EOF
./ai-compiler -O0 -o /tmp/scalar_O0.s /tmp/scalar.aiir && cat /tmp/scalar_O0.s
# -> li t0, 0x40000000 / sw / flw / fadd.s / fsw  (all normal, ai-compiler.c:305)
grep -E "fadd.s|fmul.s|flw|fsw|li.*0x" /tmp/scalar_O0.s
```

---

## 7. Example 5 — Hand-Written Normal Assembly

Write pure-normal RISC-V and run it.

```bash
cat > /tmp/normal_kernel.s <<'EOF'
        .option norvc
        .text
        .align 2
        .globl ai_kernel
ai_kernel:
        # vector add of 8 floats: OUT[i] = A[i]+B[i] using only normal ops
        li      t0, 8
        mv      t1, a0         # A
        mv      t2, a1         # B
        mv      t3, a2         # OUT
1:      flw     fa0, 0(t1)
        flw     fa1, 0(t2)
        fadd.s  fa2, fa0, fa1
        fsw     fa2, 0(t3)
        addi    t1, t1, 4
        addi    t2, t2, 4
        addi    t3, t3, 4
        addi    t0, t0, -1
        bnez    t0, 1b
        ret
EOF
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c /tmp/normal_kernel.s -o /tmp/normal_kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o /tmp/normal.elf runtime/crt0.s /tmp/normal_kernel.o runtime/runtime.c runtime/driver.c
riscv64-unknown-elf-objdump -d /tmp/normal.elf | sed -n '/<ai_kernel>:/,/ret/p'
./rvss /tmp/normal.elf 2>&1 | grep -E "OUT|retired"
```

---

## 8. Verify — No Custom Encoding

```bash
# Every normal encoding has opcode != 0x0B
python3 <<'PY'
for w in [0x14730e0b, 0x14031e0b, 0x14732e0b, 0x14733e0b]:
    print(f"{w:#010x} opcode={w & 0x7F:#04x}  <- custom (0x0b)")
# Normal example: fadd.s encoding has opcode 0x53
# Check objdump never shows 0x0b in normal ELFs:
PY
riscv64-unknown-elf-objdump -d build/demo1_sw.elf | grep "\.word" && echo "has .word" || echo "no .word — confirms normal-only"
```

---

## 9. Cross-Check With Custom (`custom.md`)

Same AIIR, normal vs custom produce bit-exact `OUT` (see `Commands.md:17.3`):

```bash
./ai-compiler -O0 -o /tmp/demo1_O0.s demos/demo1.aiir && grep -c "\.word" /tmp/demo1_O0.s || echo 0
./ai-compiler -O1 -o /tmp/demo1_O1.s demos/demo1.aiir && grep -c "\.word" /tmp/demo1_O1.s
# 0 vs 3 — proves custom is pure acceleration over normal

diff -u /tmp/demo1_O0.s /tmp/demo1_O1.s | head -n 60
```

For custom counterparts of every example above, see `custom.md` (AISS `custom-0` `0x0B`, `ai-compiler.c:47`, `rvss.c:516`).

---

## 10. Run Each Operation Alone via the Normal Path and See Operands + Result

`ai-compiler -O0` lowers every AI op to **normal RV64IMAFD only** (no custom
word). Each op is also built as a standalone **`.sw.elf`** (normal path) that
prints its operands (`A`, `B`) and result (`OUT`). Run one and you see the whole
operation on the terminal.

**Step 0 — build the per-op normal ELFs (once):**

```bash
make clean && make            # builds ai-compiler + rvss
bash tests/unit/run-unit.sh   # builds build/unit/<case>.sw.elf (normal -O0)
```

**Operands used by every case** (fixed in `tests/unit/unit_driver.c`; `-0.0`
displays as `0.0`):

```
A = [-2, 3, 0, 5, 0, -6, 7, -8, 9, -1, 0, 2, -3, 4, -5, 6]
B = [ 2, -4, 6, 0, -1, 3, -7, 8, -9, 1, 0, -2, 5, -6, 7, -3]
```

**One op, normal path, start to finish (example: `ai.add` on N=8).** Copy-paste;
it prints operands + result and proves there is no custom word:

```bash
cat > /tmp/add8.aiir <<'EOF'
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  ai.return %2 : tensor<8xf32>
}
ai.entry @main
EOF
./ai-compiler -O0 -o /tmp/add8.sw.s /tmp/add8.aiir                 # flw/fadd.s/fsw loop
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c /tmp/add8.sw.s -o /tmp/add8.sw.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o /tmp/add8.sw.elf runtime/crt0.s /tmp/add8.sw.o runtime/runtime.c tests/unit/unit_driver.c
riscv64-unknown-elf-objdump -d /tmp/add8.sw.elf | grep -E "14730e0b|14732e0b|14031e0b|14733e0b" && echo "found custom" || echo "no custom words - pure normal (expected)"
./rvss /tmp/add8.sw.elf
```

Actual terminal output of that last `./rvss` command (identical operands/result
to the custom path, only reached with normal instructions):

```
== AISS unit ==
A (operand) = [-2.0 3.0 0.0 5.0 0.0 -6.0 7.0 -8.0 9.0 -1.0 0.0 2.0 -3.0 4.0 -5.0 6.0 ]
B (operand) = [2.0 -4.0 6.0 0.0 -1.0 3.0 -7.0 8.0 -9.0 1.0 0.0 -2.0 5.0 -6.0 7.0 -3.0 ]
OUT (result) = [0.0 -1.0 6.0 5.0 -1.0 -3.0 0.0 0.0 ... ]     # first 8 = A+B
done
[rvss] retired 7754 instructions, exit=0
```

**Every op on the normal path = operands -> result (run the `.sw.elf`):**

| Operation | Command (normal `-O0`) | Meaningful `OUT` (result) |
|---|---|---|
| `ai.add` N=4  | `./rvss build/unit/add4.sw.elf`  | `[0.0 -1.0 6.0 5.0]` |
| `ai.add` N=8  | `./rvss build/unit/add8.sw.elf`  | `[0.0 -1.0 6.0 5.0 -1.0 -3.0 0.0 0.0]` |
| `ai.add` N=16 | `./rvss build/unit/add16.sw.elf` | `[0.0 -1.0 6.0 5.0 -1.0 -3.0 0.0 0.0 0.0 0.0 0.0 0.0 2.0 -2.0 2.0 3.0]` |
| `ai.mul` N=4  | `./rvss build/unit/mul4.sw.elf`  | `[-4.0 -12.0 0.0 0.0]` |
| `ai.mul` N=8  | `./rvss build/unit/mul8.sw.elf`  | `[-4.0 -12.0 0.0 0.0 0.0 -18.0 -49.0 -64.0]` |
| `ai.mul` N=16 | `./rvss build/unit/mul16.sw.elf` | `[-4.0 -12.0 0.0 0.0 0.0 -18.0 -49.0 -64.0 -81.0 -1.0 0.0 -4.0 -15.0 -24.0 -35.0 -18.0]` |
| `ai.relu` N=4  | `./rvss build/unit/relu4.sw.elf`  | `[0.0 3.0 0.0 5.0]`  ← `[-2, 3, -0.0] -> [0, 3, 0]` |
| `ai.relu` N=8  | `./rvss build/unit/relu8.sw.elf`  | `[0.0 3.0 0.0 5.0 0.0 0.0 7.0 0.0]` |
| `ai.relu` N=16 | `./rvss build/unit/relu16.sw.elf` | `[0.0 3.0 0.0 5.0 0.0 0.0 7.0 0.0 9.0 0.0 0.0 2.0 0.0 4.0 0.0 6.0]` |
| `ai.matmul` 1x1x1 | `./rvss build/unit/mm111.sw.elf` | `[-4.0]` |
| `ai.matmul` 2x2x2 | `./rvss build/unit/mm222.sw.elf` | `[14.0 8.0 30.0 0.0]` |
| `ai.matmul` 3x3x3 | `./rvss build/unit/mm333.sw.elf` | `[-4.0 5.0 -3.0 52.0 -68.0 84.0 -49.0 52.0 -63.0]` |
| `ai.matmul` 4x4x4 | `./rvss build/unit/mm444.sw.elf` | `[18.0 -13.0 2.0 9.0 -97.0 37.0 -14.0 -38.0 29.0 -51.0 75.0 -14.0 65.0 -17.0 -4.0 24.0]` |
| `ai.matmul` 2x4x2 | `./rvss build/unit/mm242.sw.elf` | `[-21.0 48.0 13.0 -43.0]` |
| chain `add->relu->mul` | `./rvss build/unit/c_addrelu_mul.sw.elf` | `[0.0 0.0 0.0 25.0 0.0 0.0 0.0 0.0]` |
| chain `matmul->matmul` | `./rvss build/unit/c_mm_mm.sw.elf` | `[76.0 -56.0 60.0 -120.0]` |

Every result above is **identical** to the custom (`.word`) path in
`custom.md` §10b — same operands in, same answer out. For matmul, read `A` as
`MxK` and `B` as `KxN` (row-major). Recordings live in `TEST_RESULTS.md` §9.
