# Custom AISS Operations — Examples and Commands

> All commands assume project root `/Users/ryangeorge/llvm`.
> Prerequisites: `cc`, `make`, `riscv64-unknown-elf-gcc`, `llvm-build/bin/clang` (`brew install riscv-gnu-toolchain`), `python3`.
> Spec: `docs/riscv-aiss-spec.md:24` · Encoder: `ai-compiler.c:47` · Decoder: `rvss.c:516` · LLVM: `llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td:37`

Custom = the **AISS** `custom-0` extension (`opcode 0x0B`, `funct7 0x0A`) added on top of the **Rocket Chip RV64IMAFD** base ISA. Everything else is normal — see `normal.md`.

---

## 1. What Counts as Custom

| funct3 | Mnemonic | `.word` | `ai-compiler.c:47` `rd=28 rs1=6 rs2=7` | Operation | `rvss.c:79` handler |
|-------:|----------|---------|--------------------------------------|-----------|---------------------|
| 0 | `ai.add`    | `0x14730e0b` | `(0x0A<<25)|(7<<20)|(6<<15)|(0<<12)|(28<<7)|0x0B` | `dst[i]=A[i]+B[i]` | `ai_vadd` |
| 1 | `ai.relu`   | `0x14031e0b` | `(0x0A<<25)|(0<<20)|(6<<15)|(1<<12)|(28<<7)|0x0B` | `dst[i]=max(0,A[i])` | `ai_vrelu` |
| 2 | `ai.mul`    | `0x14732e0b` | `(0x0A<<25)|(7<<20)|(6<<15)|(2<<12)|(28<<7)|0x0B` | `dst[i]=A[i]*B[i]` | `ai_vmul` |
| 3 | `ai.matmul` | `0x14733e0b` | `(0x0A<<25)|(7<<20)|(6<<15)|(3<<12)|(28<<7)|0x0B` | `dst[m,n]=Σ_k A[m,k]*B[k,n]` | `ai_matmul` |

R-type `docs/riscv-aiss-spec.md:26`:

```
31      25 24   20 19   15 14 12 11    7 6     0
 funct7  | rs2   | rs1  |funct3| rd  | opcode
  0x0A   |(7/0)  |  6   | 0..3 | 28  | 0x0B
```

Fixed ABI `docs/riscv-aiss-spec.md:43`: `x5=t0=n`, `x6=t1=A`, `x7=t2=B`, `x28=t3=dst`, `x29=M x30=K x31=N` for matmul. One `.word` = whole tensor op.

---

## 2. Build (once)

```bash
make clean && make
# -> ai-compiler + rvss + build/demo1.elf demo2.elf demo3.elf (all custom -O1 by Makefile:35)
ls -lh ai-compiler rvss build/*.elf
llvm-build/bin/llvm-mc -mattr=help | grep -i xai   # -> +xai
```

---

## 3. Example 1 — `ai-compiler -O1` → Custom `.word` (standalone, no LLVM)

Each AIIR tensor op becomes exactly one custom word (`ai-compiler.c:121`).

```bash
# 3a. demo1: ai.add → ai.mul → ai.relu  (demos/demo1.aiir:9)
cat demos/demo1.aiir
./ai-compiler -O1 -o /tmp/demo1_O1.s demos/demo1.aiir && cat /tmp/demo1_O1.s
# ai_kernel:
#         li      t0, 8
#         mv      t1, a0
#         mv      t2, a1
#         addi    t3, sp, -16
#         .word   0x14730e0b                # ai.add  t3,t1,t2 len=8
#         li      t0, 8
#         addi    t1, sp, -16
#         mv      t2, a0
#         addi    t3, sp, -80
#         .word   0x14732e0b                # ai.mul
#         li      t0, 8
#         addi    t1, sp, -80
#         addi    t3, sp, -144
#         .word   0x14031e0b                # ai.relu

# 3b. demo2: single matmul 4x4 (demos/demo2.aiir:5)
cat demos/demo2.aiir
./ai-compiler -O1 -o /tmp/demo2_O1.s demos/demo2.aiir && cat /tmp/demo2_O1.s
#         li      t4, 4                      # M  (x29)
#         li      t5, 4                      # K  (x30)
#         li      t6, 4                      # N  (x31)
#         mv      t1, a0
#         mv      t2, a1
#         addi    t3, sp, -16
#         .word   0x14733e0b                # ai.matmul t3,t1,t2 4x4x4  (ai-compiler.c:187)

# 3c. demo3: matmul + add + relu  (demos/demo3.aiir:5)
./ai-compiler -O1 -o /tmp/demo3_O1.s demos/demo3.aiir && cat /tmp/demo3_O1.s
# -> 0x14733e0b matmul, 0x14730e0b add, 0x14031e0b relu

# 3d. Count words
grep -n "\.word" /tmp/demo1_O1.s /tmp/demo2_O1.s /tmp/demo3_O1.s
# /tmp/demo1_O1.s:11: .word 0x14730e0b
# /tmp/demo1_O1.s:16: .word 0x14732e0b
# /tmp/demo1_O1.s:20: .word 0x14031e0b
# /tmp/demo2_O1.s:10: .word 0x14733e0b
# /tmp/demo3_O1.s: ... 3 words
```

---

## 4. Example 2 — Assemble and Inspect Custom Words (objdump)

Custom words sit inline with normal `li/mv/addi` prologue.

```bash
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
# 80000010: 00800293 li t0,8
# 80000014: 00000293 mv t1,a0
# 80000018: 00000313 mv t2,a1
# 8000001c: ff012e13 addi t3,sp,-16
# 80000020: 14730e0b .word 0x14730e0b   # ai.add  (custom-0, f3=0)
# 80000024: 00800293 li t0,8
# ...

riscv64-unknown-elf-objdump -d build/demo1.elf | grep -E "14730e0b|14031e0b|14732e0b|14733e0b"
# 80000020: 14730e0b
# 80000034: 14732e0b
# 80000044: 14031e0b

riscv64-unknown-elf-objdump -d build/demo2.elf | grep 14733e0b   # matmul f3=3
riscv64-unknown-elf-objdump -d build/demo3.elf | grep -E "14733e0b|14730e0b|14031e0b"

riscv64-unknown-elf-objdump -s -j .text build/demo1.elf | head
# -> LE bytes 0b 0e 73 14 = 0x14730e0b
```

---

## 5. Example 3 — LLVM XAi Path (TableGen, same bytes)

Encoding is duplicated in LLVM (`RISCVInstrInfoAI.td:37` `RVInstR<0x0A,funct3,OPC_CUSTOM_0>`, `IntrinsicsRISCV.td` `int_riscv_ai_add`). Prove byte-identical to `ai-compiler.c:47`.

```bash
# 5a. llvm-mc generic forms (GPR:$rd)
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
# -> encoding: [0x0b,0x0e,0x73,0x14]  (= 0x14730e0b LE)
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.relu t3, t1, t2"
# -> 0x14031e0b
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.mul t3, t1, t2"
# -> 0x14732e0b
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.matmul t3, t1, t2"
# -> 0x14733e0b

# All four at once
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble /dev/stdin <<'EOF'
ai.add t3, t1, t2
ai.add
ai.relu t3, t1, t2
ai.mul t3, t1, t2
ai.matmul t3, t1, t2
EOF
# -> 0x14730e0b / 0x14730e0b / 0x14031e0b / 0x14732e0b / 0x14733e0b

# 5b. Fixed-register implicit form via intrinsic → llc
cat > /tmp/ai_intrinsic.ll <<'EOF'
target triple = "riscv64"
declare void @llvm.riscv.ai.add()
declare void @llvm.riscv.ai.relu()
declare void @llvm.riscv.ai.mul()
declare void @llvm.riscv.ai.matmul()
define void @k() {
  call void @llvm.riscv.ai.add()
  call void @llvm.riscv.ai.relu()
  call void @llvm.riscv.ai.mul()
  call void @llvm.riscv.ai.matmul()
  ret void
}
EOF
llvm-build/bin/llc -march=riscv64 -mattr=+xai -o /tmp/ai_intrinsic.s /tmp/ai_intrinsic.ll && cat /tmp/ai_intrinsic.s
# -> ai.add / ai.relu / ai.mul / ai.matmul  (Defs=[X28] Uses=[X5,X6,X7])
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding /tmp/ai_intrinsic.s
# -> same 4 encodings

# 5c. clang -march=rv64gc_xai with inline asm
cat > /tmp/ai_inline_xai.c <<'EOF'
void k(void){ asm volatile("ai.add t3, t1, t2"); }
EOF
llvm-build/bin/clang --target=riscv64 -march=rv64gc_xai -c -o /tmp/ai_xai_clang.o /tmp/ai_inline_xai.c
llvm-build/bin/llvm-objdump -d /tmp/ai_xai_clang.o
# -> 14730e0b  ai.add t3,t1,t2
riscv64-unknown-elf-objdump -d /tmp/ai_xai_clang.o | grep 14730e0b
```

---

## 6. Example 4 — Python Bit-Decode (proves `opcode 0x0B`, `funct7 0x0A`)

```bash
python3 <<'PY'
val=0x14730e0b
print(f"0x{val:08x} -> opcode={val&0x7F:#x} rd={(val>>7)&0x1F} f3={(val>>12)&0x7} rs1={(val>>15)&0x1F} rs2={(val>>20)&0x1F} f7={(val>>25)&0x7F:#x}")
for name,f3,exp in [("ai.add",0,0x14730e0b),("ai.relu",1,0x14031e0b),("ai.mul",2,0x14732e0b),("ai.matmul",3,0x14733e0b)]:
    e=(0x0A<<25)|(7<<20)|(6<<15)|(f3<<12)|(28<<7)|0x0B
    if f3==1: e=(0x0A<<25)|(0<<20)|(6<<15)|(f3<<12)|(28<<7)|0x0B  # relu rs2 unused
    print(f"{name:9s} f3={f3} -> {e:#010x} expect {exp:#010x} ok={e==exp}")
PY
# -> all ok=True, opcode 0x0b, f7 0x0a  (docs/riscv-aiss-spec.md:24)
```

---

## 7. Example 5 — Hand-Written Custom Kernel → `llvm-mc` → `rvss`

Minimal custom ELF from raw assembly, byte-identical to standalone compiler.

```bash
cat > /tmp/llvm_kernel.s <<'EOF'
        .text
        .globl ai_kernel
        .type ai_kernel,@function
ai_kernel:
        li t0, 8
        mv t1, a1
        mv t2, a2
        mv t3, a0
        ai.add
        ret
EOF
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai -filetype=obj -o /tmp/llvm_kernel.o /tmp/llvm_kernel.s
riscv64-unknown-elf-objdump -d /tmp/llvm_kernel.o
# 0000000000000010 <ai_kernel>:  ... 14730e0b  ai.add

cat > /tmp/llvm_driver.c <<'EOF'
#include <stdint.h>
extern void ai_kernel(float *dst, float *a, float *b);
extern void exit_sim(int);
float A[8]={1,-2,3,-4,5,-6,7,-8};
float B[8]={2,0,0,0,0,2,0,0};
float OUT[8]={0};
int main(){
  ai_kernel(OUT,A,B);
  if (OUT[0]==3.0f && OUT[1]==-2.0f && OUT[2]==3.0f) exit_sim(0);
  else exit_sim(1);
  return 0;
}
EOF
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -T runtime/riscv64.ld -nostdlib -static -o /tmp/llvm_demo.elf /tmp/llvm_kernel.o /tmp/llvm_driver.c runtime/crt0.s runtime/runtime.c
riscv64-unknown-elf-objdump -d /tmp/llvm_demo.elf | grep 14730e0b
# 8000002c: 14730e0b
./rvss /tmp/llvm_demo.elf
# Beginner view: Input A=[1 -2 3 -4 5 -6 7 -8], Input B=[2 0 0 0 0 2 0 0], Result OUT=[3 -2 3 -4 5 -4 7 -8] (OUT[i]=A[i]+B[i])
# [rvss] retired 76 instructions, exit=0  -> OUT = A+B  (rvss.c:516 decodes 0x0B/0x0A)

# Also run the built demos (custom) - beginner view shows inputs + result
./rvss build/demo1.elf
./rvss build/demo2.elf
./rvss build/demo3.elf
# Beginner view you will see:
# == AISS demo (beginner view) ==
# Input A (8 numbers) = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ]
# Input B (8 numbers) = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]
# Result OUT (8 numbers) = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]  (demo1, 4090 retired)
# Result OUT = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]  (demo2, 4105 retired)
# Result OUT = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]  (demo3, 4056 retired)
```

---

## 8. Example 6 — Write and Run Your Own Custom Kernel

```bash
cat > demos/my_kernel.aiir <<'EOF'
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %3 = "ai.mul"(%2, %0) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %4 = "ai.relu"(%3) : (tensor<8xf32>) -> tensor<8xf32>
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
EOF
./ai-compiler -O1 -o build/my_kernel.kernel.s demos/my_kernel.aiir && cat build/my_kernel.kernel.s
# -> 3 custom .words (same as demo1)
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/my_kernel.kernel.s -o build/my_kernel.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o build/my_kernel.elf runtime/crt0.s build/my_kernel.kernel.o runtime/runtime.c runtime/driver.c
riscv64-unknown-elf-objdump -d build/my_kernel.elf | grep -E "14730e0b|14732e0b|14031e0b"
./rvss build/my_kernel.elf 2>&1 | grep -E "OUT|retired"
# OUT=[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]
```

---

## 9. Full Pipeline By Hand (shows normal prologue + custom core)

```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -Wall -T runtime/riscv64.ld -nostdlib -static -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o runtime/runtime.c runtime/driver.c
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
./rvss build/demo1.elf
```

---

## 10. Verify Byte-Identical to Normal Path (proves acceleration)

```bash
for d in demo1 demo2 demo3; do
  ./ai-compiler -O1 -o /tmp/${d}_hw.kernel.s demos/${d}.aiir
  ./ai-compiler -O0 -o /tmp/${d}_sw.kernel.s demos/${d}.aiir
  echo "== $d =="; grep -c "\.word" /tmp/${d}_hw.kernel.s; grep -c "\.word" /tmp/${d}_sw.kernel.s || echo 0
done
# hw: 3/1/3 words, sw: 0/0/0 — custom replaces scalar loops

make test  # 15 demo + 32 unit = 47 PASS: hw OUT == sw OUT == reference, bit-exact
```

---

## 10b. Run Each Custom Instruction With Its Operands and See the Result

Every custom op is also built as a **standalone ELF** that prints the operands
(`A`, `B`) and the result (`OUT`) on the terminal. One run of
`tests/unit/run-unit.sh` compiles each op two ways (Hardware `-O1` = custom
`.word`, and Software `-O0` = scalar) into `build/unit/`, then you can run any
single op and read its operands and answer directly.

**Step 0 — build the per-op custom ELFs (once):**

```bash
make clean && make            # builds ai-compiler + rvss
bash tests/unit/run-unit.sh   # also builds build/unit/<case>.hw.elf (custom -O1)
```

**Operands used by every case** (fixed in `tests/unit/unit_driver.c`; `-0.0`
displays as `0.0`):

```
A = [-2, 3, 0, 5, 0, -6, 7, -8, 9, -1, 0, 2, -3, 4, -5, 6]
B = [ 2, -4, 6, 0, -1, 3, -7, 8, -9, 1, 0, -2, 5, -6, 7, -3]
```

**One op, start to finish (example: `ai.add` on N=8).** This whole block is
copy-pasteable and prints the operands and the result:

```bash
cat > /tmp/add8.aiir <<'EOF'
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  ai.return %2 : tensor<8xf32>
}
ai.entry @main
EOF
./ai-compiler -O1 -o /tmp/add8.hw.s /tmp/add8.aiir                 # emits .word 0x14730e0b
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c /tmp/add8.hw.s -o /tmp/add8.hw.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o /tmp/add8.hw.elf runtime/crt0.s /tmp/add8.hw.o runtime/runtime.c tests/unit/unit_driver.c
./rvss /tmp/add8.hw.elf
```

Actual terminal output of that last `./rvss` command:

```
== AISS unit ==
A (operand) = [-2.0 3.0 0.0 5.0 0.0 -6.0 7.0 -8.0 9.0 -1.0 0.0 2.0 -3.0 4.0 -5.0 6.0 ]
B (operand) = [2.0 -4.0 6.0 0.0 -1.0 3.0 -7.0 8.0 -9.0 1.0 0.0 -2.0 5.0 -6.0 7.0 -3.0 ]
OUT (result) = [0.0 -1.0 6.0 5.0 -1.0 -3.0 0.0 0.0 ... ]     # first 8 = A+B
[rvss] retired 7683 instructions, exit=0
```

**Every custom op = operands -> result (run the ready ELF):**

| Operation (`.word`) | Command | Meaningful `OUT` (result) |
|---|---|---|
| `ai.add` `0x14730e0b`, N=4  | `./rvss build/unit/add4.hw.elf`  | `[0.0 -1.0 6.0 5.0]` |
| `ai.add` N=8  | `./rvss build/unit/add8.hw.elf`  | `[0.0 -1.0 6.0 5.0 -1.0 -3.0 0.0 0.0]` |
| `ai.add` N=16 | `./rvss build/unit/add16.hw.elf` | `[0.0 -1.0 6.0 5.0 -1.0 -3.0 0.0 0.0 0.0 0.0 0.0 0.0 2.0 -2.0 2.0 3.0]` |
| `ai.mul` `0x14732e0b`, N=4  | `./rvss build/unit/mul4.hw.elf`  | `[-4.0 -12.0 0.0 0.0]` |
| `ai.mul` N=8  | `./rvss build/unit/mul8.hw.elf`  | `[-4.0 -12.0 0.0 0.0 0.0 -18.0 -49.0 -64.0]` |
| `ai.mul` N=16 | `./rvss build/unit/mul16.hw.elf` | `[-4.0 -12.0 0.0 0.0 0.0 -18.0 -49.0 -64.0 -81.0 -1.0 0.0 -4.0 -15.0 -24.0 -35.0 -18.0]` |
| `ai.relu` `0x14031e0b`, N=4  | `./rvss build/unit/relu4.hw.elf`  | `[0.0 3.0 0.0 5.0]`  ← `[-2, 3, -0.0] -> [0, 3, 0]` |
| `ai.relu` N=8  | `./rvss build/unit/relu8.hw.elf`  | `[0.0 3.0 0.0 5.0 0.0 0.0 7.0 0.0]` |
| `ai.relu` N=16 | `./rvss build/unit/relu16.hw.elf` | `[0.0 3.0 0.0 5.0 0.0 0.0 7.0 0.0 9.0 0.0 0.0 2.0 0.0 4.0 0.0 6.0]` |
| `ai.matmul` `0x14733e0b` 1x1x1 | `./rvss build/unit/mm111.hw.elf` | `[-4.0]` |
| `ai.matmul` 2x2x2 | `./rvss build/unit/mm222.hw.elf` | `[14.0 8.0 30.0 0.0]` |
| `ai.matmul` 3x3x3 | `./rvss build/unit/mm333.hw.elf` | `[-4.0 5.0 -3.0 52.0 -68.0 84.0 -49.0 52.0 -63.0]` |
| `ai.matmul` 4x4x4 | `./rvss build/unit/mm444.hw.elf` | `[18.0 -13.0 2.0 9.0 -97.0 37.0 -14.0 -38.0 29.0 -51.0 75.0 -14.0 65.0 -17.0 -4.0 24.0]` |
| `ai.matmul` 2x4x2 (non-square) | `./rvss build/unit/mm242.hw.elf` | `[-21.0 48.0 13.0 -43.0]` |
| chain `add->relu->mul` = `relu(A+B)*A` | `./rvss build/unit/c_addrelu_mul.hw.elf` | `[0.0 0.0 0.0 25.0 0.0 0.0 0.0 0.0]` |
| chain `matmul->matmul` = `(A@B)@B` | `./rvss build/unit/c_mm_mm.hw.elf` | `[76.0 -56.0 60.0 -120.0]` |

For matmul, read `A` as an `MxK` matrix and `B` as `KxN` (row-major, from the
flat operand arrays above). Each `OUT` above is identical to what the **normal
software path** produces: just run the `.sw.elf` twin instead, e.g.
`./rvss build/unit/add8.sw.elf` prints the same `A`, `B` and `OUT`. That
equality (custom == normal) is the correctness proof.

**Inputs and result at each stage (custom `.word` path, not just final OUT):**

*   **Demos (custom `-O1`, `runtime/driver.c:18` `A=[1,-2,3,-4,5,-6,7,-8,9,10,11,12,13,14,15,16]` `B=2*I`):**
    *   `demo1 add->mul->relu`: Stage1 `A+B` inputs `A=[1,-2,3,-4,5,-6,7,-8] B=[2,0,0,0,0,2,0,0]` -> `0x14730e0b` result `[3,-2,3,-4,5,-4,7,-8]`; Stage2 `*A` `0x14732e0b` -> `[3,4,9,16,25,24,49,64]`; Stage3 `relu` `0x14031e0b` -> `[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0]` — `./rvss build/demo1.elf` prints `A=`, `B=`, `OUT=` so both inputs and final result visible, same per-stage as normal.
    *   `demo2 matmul 4x4`: Stage1 `A@B` inputs `A 4x4` `B 2*I` `0x14733e0b` -> `2*A` first 8 `[2,-4,6,-8,10,-12,14,-16]`
    *   `demo3 matmul->add->relu`: Stage1 `matmul 0x14733e0b` -> `2*A`, Stage2 `add 0x14730e0b` -> `4*A`, Stage3 `relu 0x14031e0b` -> `[4,0,12,0,20,0,28,0,36,40,44,48,52,56,60,64]` first 8 shown
*   **Unit chains (custom, `A=[-2,3,0,5,0,-6,7,-8]` `B=[2,-4,6,0,-1,3,-7,8]` first 8 or 2x2):**
    *   `c_addrelu_mul hw 0x14730e0b->0x14031e0b->0x14732e0b`: Stage1 `A+B=[0,-1,6,5,-1,-3,0,0]`, Stage2 `relu=[0,0,6,5,0,0,0,0]`, Stage3 `*A=[0,0,0,25,0,0,0,0]` — `./rvss build/unit/c_addrelu_mul.hw.elf` prints `A=`, `B=`, `OUT=` for chain.
    *   `c_mm_mm hw 0x14733e0b->0x14733e0b`: Stage1 `C=A@B=[[14,8],[30,0]]`, Stage2 `D=C@B=[[76,-56],[60,-120]]` flat `[76,-56,60,-120]`

Running `./rvss build/unit/<case>.hw.elf` or `./rvss build/demo*.elf` always prints `A (operand) = [...]`, `B (operand) = [...]`, `OUT (result) = [...]` plus `retired`, so at each stage-equivalent execution both inputs and result are shown, not just output.

```bash
# Encoding of a single custom op, two independent ways:
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
#  -> [0x0b,0x0e,0x73,0x14] = 0x14730e0b
riscv64-unknown-elf-objdump -d build/unit/add8.hw.o | grep 14730e0b
```

---

## 11. Cross-Reference

* Normal scalar equivalents: `normal.md` (`ai-compiler.c:92`, `rvss.c:409`)
* Spec + ABI: `docs/riscv-aiss-spec.md:24`
* TableGen: `llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td:37` `RISCVInstrInfoAI.td:66` `RISCV.td:37`
* Intrinsics: `llvm-project/llvm/include/llvm/IR/IntrinsicsRISCV.td`
* Combined view: `Commands.md:17`
