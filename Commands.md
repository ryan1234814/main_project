# Commands — AISS RISC-V AI-instruction demo (reproduces `TEST_RESULTS.md`)

All commands assume you are in the project root (`/Users/ryangeorge/llvm`).
Prerequisites (already installed): `cc`, `make`, `riscv64-unknown-elf-gcc` (`brew install riscv-gnu-toolchain`), `python3`, `ninja`.
The terminal outputs below are exactly those pasted into `TEST_RESULTS.md`. Each section maps 1:1 to a `TEST_RESULTS.md` § — run them in order to reproduce that file.

---

## 0. Verify LLVM build (TEST_RESULTS.md §1.1)

```bash
llvm-build/bin/clang --version   # clang 20.1.8
llvm-build/bin/llc --version     # LLVM 20.1.8 riscv32/riscv64
ninja -C llvm-build -j8 llc llvm-mc llvm-objdump clang   # no work to do if already built
llvm-build/bin/llvm-mc -mattr=help | grep -i xai          # should list +xai if XAi patch applied
```

Expected: `Registered Targets: riscv32 riscv64`. To rebuild from source:

```bash
cmake -S llvm/llvm -B llvm-build -G Ninja \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_TARGETS_TO_BUILD="RISCV" \
  -DCMAKE_BUILD_TYPE=Release
ninja -C llvm-build -j8 clang llc llvm-mc llvm-objdump
```

---

## 1. Build everything — host tools + 3 demo ELFs (TEST_RESULTS.md §1 / §4.5)

```bash
make clean && make
ls -lh ai-compiler rvss build/*.elf   # ai-compiler, rvss, build/demo1.elf demo2.elf demo3.elf
```

Builds `ai-compiler` (AI dialect → RISC-V, `-O1` custom `.word` / `-O0` scalar), `rvss` (ISS + AI unit `rvss.c:516`), and demos via `-march=rv64imafd -mabi=lp64 -mcmodel=medany`.

---

## 2. Step 1 — Trivial C cross-compile via `llvm-build/bin/clang --target=riscv64` + `llc` + `llvm-objdump` (TEST_RESULTS.md §1.2)

Copy-paste exactly (produces `addw` lowering):

```bash
cat > /tmp/trivial.c <<'EOF'
int add(int a,int b){return a+b;}
int main(){return add(2,3);}
EOF

llvm-build/bin/clang --target=riscv64 -march=rv64gc -S -o /tmp/trivial.s /tmp/trivial.c
cat /tmp/trivial.s   # -> addw a0,a0,a1

llvm-build/bin/clang --target=riscv64 -march=rv64gc -emit-llvm -S -o /tmp/trivial.ll /tmp/trivial.c
cat /tmp/trivial.ll  # -> target triple riscv64-unknown-unknown, %7 = add nsw i32

llvm-build/bin/llc -march=riscv64 -mattr=+m,+a,+f,+d,+c -o /tmp/trivial_llc.s /tmp/trivial.ll
cat /tmp/trivial_llc.s  # -> same as above + .option arch

llvm-build/bin/clang --target=riscv64 -march=rv64gc -c -o /tmp/trivial.o /tmp/trivial.c
llvm-build/bin/llvm-objdump -d /tmp/trivial.o
# /tmp/trivial.o: file format elf64-littleriscv
# 0000000000000000 <add>: ... 9d2d  addw a0,a0,a1 ...

llvm-build/bin/llvm-mc -triple=riscv64 --show-encoding /tmp/trivial_llc.s
# addw a0,a0,a1  # encoding: [0x2d,0x9d]
```

**Correctness:** `add nsw i32` → `addw`, object valid, `llvm-objdump`/`llvm-mc` agree → **Step 1 PASS** (matches TEST_RESULTS.md §1.2).

---

## 3. Step 2 — Study backend files (TEST_RESULTS.md §2)

No execution — read-only. Confirm which TableGen base class / register class / files you will edit:

```bash
grep -n "class RVInstR" llvm-project/llvm/lib/Target/RISCV/RISCVInstrFormats.td | head
# class RVInstRBase / RVInstR  (RISCVInstrFormats.td:347)
grep -n "OPC_CUSTOM_0" llvm-project/llvm/lib/Target/RISCV/RISCVInstrFormats.td
# def OPC_CUSTOM_0 : RISCVOpcode<"CUSTOM_0",0b0001011>; // :135
grep -n "def ADD :" llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfo.td | head
# def ADD : ALU_rr<0b0000000,0b000,"add">  // :691
grep -n "class GPR" llvm-project/llvm/lib/Target/RISCV/RISCVRegisterInfo.td | head
ls llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td llvm-project/llvm/include/llvm/IR/IntrinsicsRISCV.td
```

Mapping answer (paste into report): base class `RVInstR<0x0A,funct3,OPC_CUSTOM_0>`, register class `GPR` (`X5=t0 X6=t1 X7=t2 X28=t3`), files `RISCVInstrInfoAI.td` / `RISCV.td:37` / `IntrinsicsRISCV.td`.

---

## 4. Step 3 — Inspect AI_ADD TableGen (TEST_RESULTS.md §3)

```bash
cat llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td
# shows FeatureVendorXAi / HasVendorXAi / AI_ADD_IMPLICIT (Defs=[X28] Uses=[X5,X6,X7] rs1=6 rs2=7 rd=28) -> 0x14730e0b
# + generic AI_ADD GPR:$rd forms, Pat<(int_riscv_ai_add),(AI_ADD_IMPLICIT)>

grep -n "RISCVInstrInfoAI" llvm-project/llvm/lib/Target/RISCV/RISCV.td
# include "RISCVInstrInfoAI.td" at :37
grep -n "int_riscv_ai" llvm-project/llvm/include/llvm/IR/IntrinsicsRISCV.td | head
# int_riscv_ai_add/relu/mul/matmul under TargetPrefix="riscv"

ninja -C llvm-build -j8 llc llvm-mc llvm-objdump clang   # verify clean build (82/972 targets)
```

**Correctness:** `llvm-tblgen` clean; encodings `0x14730e0b` etc. hard-wired.

---

## 5. Step 4 — End-to-end: `.ll -> llc -mattr=+xai -> 0x14730e0b -> rvss` (TEST_RESULTS.md §4)

### 5.1 Hand-written `.ll` intrinsic → `llc` → `llvm-mc` encoding

```bash
cat > /tmp/ai_intrinsic2.ll <<'EOF'
target triple = "riscv64"
declare void @llvm.riscv.ai.add()
define void @k() {
  call void @llvm.riscv.ai.add()
  ret void
}
EOF
cat /tmp/ai_intrinsic2.ll

llvm-build/bin/llc -march=riscv64 -mattr=+xai -o /tmp/ai_intrinsic2.s /tmp/ai_intrinsic2.ll
cat /tmp/ai_intrinsic2.s   # -> ai.add / ret, attribute xai1p0

llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding /tmp/ai_intrinsic2.s
# k: ai.add  # encoding: [0x0b,0x0e,0x73,0x14]  (= 0x14730e0b LE)
```

Generic form (also valid):

```bash
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
# ai.add t3,t1,t2  # encoding: [0x0b,0x0e,0x73,0x14]

llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble /dev/stdin <<'EOF'
ai.add t3, t1, t2
ai.add
ai.relu t3, t1, t2
ai.mul t3, t1, t2
ai.matmul t3, t1, t2
EOF
# -> 0x14730e0b / 0x14730e0b / 0x14031e0b / 0x14732e0b / 0x14733e0b
```

### 5.2 Python bit-decode (byte-identical to standalone `ai-compiler.c:47`)

```bash
python3 <<'PY'
val=0x14730e0b
print(f"0x{val:08x} -> opcode={val&0x7F:#x} rd={(val>>7)&0x1F} f3={(val>>12)&0x7} rs1={(val>>15)&0x1F} rs2={(val>>20)&0x1F} f7={(val>>25)&0x7F:#x}")
enc=(0x0A<<25)|(7<<20)|(6<<15)|(0<<12)|(28<<7)|0x0B
print(f"encode rd28 rs1 6 rs2 7 f7 0x0A f3 0 opc 0x0B = {enc:#010x} match={enc==val}")
for name,f3,exp in [("add",0,0x14730e0b),("relu",1,0x14031e0b),("mul",2,0x14732e0b),("matmul",3,0x14733e0b)]:
    e=(0x0A<<25)|(7<<20)|(6<<15)|(f3<<12)|(28<<7)|0x0B
    if f3==1: e=(0x0A<<25)|(0<<20)|(6<<15)|(f3<<12)|(28<<7)|0x0B
    print(f"{name} f3={f3} -> {e:#010x} expect {exp:#010x} ok={e==exp}")
PY
# -> all ok=True
```

### 5.3 Clang XAi integration

```bash
cat > /tmp/ai_inline_xai.c <<'EOF'
void k(void){ asm volatile("ai.add t3, t1, t2"); }
EOF
llvm-build/bin/clang --target=riscv64 -march=rv64gc_xai -c -o /tmp/ai_xai_clang.o /tmp/ai_inline_xai.c
llvm-build/bin/llvm-objdump -d /tmp/ai_xai_clang.o
# 8: 14730e0b  <unknown>  -> bytes 0b 0e 73 14 (GNU objdump shows .insn, LLVM shows ai.add with +xai)
riscv64-unknown-elf-objdump -d /tmp/ai_xai_clang.o | grep 14730e0b
```

### 5.4 Simulator cross-verify — LLVM ELF vs standalone ELF (byte-for-byte + numeric)

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
# 10: 14730e0b  .insn 4, 0x14730e0b

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
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -T runtime/riscv64.ld -nostdlib -o /tmp/llvm_demo.elf /tmp/llvm_kernel.o /tmp/llvm_driver.c runtime/crt0.s runtime/runtime.c
riscv64-unknown-elf-objdump -d /tmp/llvm_demo.elf | grep 14730e0b
# 8000002c: 14730e0b

./rvss /tmp/llvm_demo.elf
# [rvss] retired 76 instructions, exit=0   -> OUT = A+B = [3.0 -2.0 3.0 -4.0 5.0 ...] PASS

./rvss build/demo1.elf
# == AISS demo == A = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ] B = [2.0 ...]
# OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]  (relu((A+B)*A))
# [rvss] retired 4090 instructions, exit=0
```

Exit 0 on LLVM ELF proves IEEE-754 bit-exact `ai_vadd` (`rvss.c:79`) and byte-identical encoding to standalone `ai-compiler.c:47`.

---

## 6. Full test suite (TEST_RESULTS.md §4.5)

```bash
make test
# equivalent: bash tests/run-tests.sh
```

Expected (all **PASS**, exit 0):

```
PASS: demo1 exit ok
PASS: demo1 prints header
PASS: demo1 prints done
PASS: demo2 exit ok
PASS: demo2 prints header
PASS: demo2 prints done
PASS: demo3 exit ok
PASS: demo3 prints header
PASS: demo3 prints done
PASS: demo1 relu((A+B)*A)
PASS: demo2 ai.matmul 4x4
PASS: demo3 matmul+add+relu
PASS: sw demo1 matches hardware
PASS: sw demo2 matches hardware
PASS: sw demo3 matches hardware
done.
```

Numeric table (verified HW vs SW bit-exact, see TEST_RESULTS.md §4.5):

| Demo | Expected OUT | HW (`-O1`) | SW (`-O0`) |
|------|--------------|------------|------------|
| demo1 `ai.add->mul->relu` | `[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]` | 4090 | 4091 PASS |
| demo2 `matmul 4x4` | `[2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]` | 4105 | 5042 PASS |
| demo3 `matmul+add+relu` | `[4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]` | 4056 | 5147 PASS |

---

## 7. Run individual demos

```bash
make demo1   # ./rvss build/demo1.elf -> OUT=[3.0 4.0 9.0 ...] 4090 retired
make demo2   # -> OUT=[2.0 -4.0 ...] 4105
make demo3   # -> OUT=[4.0 0.0 ...] 4056
for d in demo1 demo2 demo3; do echo "== $d =="; ./rvss build/$d.elf 2>&1 | grep -E "OUT|retired"; done
```

---

## 8. Compile a demo by hand (shows every pipeline stage)

```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -Wall -T runtime/riscv64.ld -nostdlib -static -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o runtime/runtime.c runtime/driver.c
./rvss build/demo1.elf
```

---

## 9. Software-fallback path (`-O0` scalar, no custom hardware)

```bash
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o build/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/${d}_sw.kernel.s -o build/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o build/${d}_sw.elf runtime/crt0.s build/${d}_sw.kernel.o runtime/runtime.c runtime/driver.c
  echo "== $d (software) =="; ./rvss build/${d}_sw.elf 2>&1 | grep OUT
done
# OUT lines must match §6 exactly -> proves custom is pure acceleration
```

---

## 10. Inspect custom AI instructions — assembly and binary (TEST_RESULTS.md §6)

```bash
grep -n "\.word" build/demo1.kernel.s build/demo2.kernel.s build/demo3.kernel.s
# -> 0x14730e0b add, 0x14031e0b relu, 0x14732e0b mul, 0x14733e0b matmul

riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
riscv64-unknown-elf-objdump -d build/demo1.elf | grep -E "\.word|14730e0b|14031e0b|14732e0b|14733e0b"
# 80000030: 14730e0b .word 0x14730e0b  # add f3=0
# 80000044: 14732e0b .word 0x14732e0b  # mul f3=2
# 80000054: 14031e0b .word 0x14031e0b  # relu f3=1
riscv64-unknown-elf-objdump -d build/demo2.elf | grep 14733e0b  # matmul f3=3
riscv64-unknown-elf-objdump -s -j .text build/demo1.elf | head
# contains 0b 0e 73 14 ... LE bytes

# LLVM XAi encodings (same bytes)
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.matmul t3, t1, t2"
```

Cross-check: `opcode 0x0B && funct7 0x0A` → `docs/riscv-aiss-spec.md:24` and `RISCVInstrFormats.td:135`.

---

## 11. Disassemble full ELFs

```bash
riscv64-unknown-elf-objdump -d build/demo1.elf | less
make dump-demo1; make dump-demo2; make dump-demo3
# dumps bare-metal image loaded at 0x80000000
```

---

## 12. Simulator debug switches

```bash
RVSS_TRACE=1 ./rvss build/demo1.elf          # dump last 256 insns on error
RVSS_MAX=100000 ./rvss build/demo1.elf       # cap budget
RVSS_BRK=0x80000020 ./rvss build/demo1.elf   # dump regs at PC
RVSS_WATCH=1 ./rvss build/demo1.elf          # trace stores to stack/OUT
RVSS_FMA=1 ./rvss build/demo1_sw.elf         # trace FP FMA
```

---

## 13. Compare `-O0` vs `-O1` lowering

```bash
./ai-compiler -O1 -o /tmp/demo1_O1.s demos/demo1.aiir && wc -l /tmp/demo1_O1.s && grep -c "\.word" /tmp/demo1_O1.s && cat /tmp/demo1_O1.s
./ai-compiler -O0 -o /tmp/demo1_O0.s demos/demo1.aiir && wc -l /tmp/demo1_O0.s && grep -c "\.word" /tmp/demo1_O0.s && cat /tmp/demo1_O0.s
# -O1: 3× .word compact; -O0: flw/fadd.s/fsw loops, no .word
```

---

## 14. Write and run your own AI kernel

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
./ai-compiler -O1 -o build/my_kernel.kernel.s demos/my_kernel.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/my_kernel.kernel.s -o build/my_kernel.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o build/my_kernel.elf runtime/crt0.s build/my_kernel.kernel.o runtime/runtime.c runtime/driver.c
./rvss build/my_kernel.elf   # OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ] (same as demo1)
```

---

## 15. Verify exit codes and retired counts (TEST_RESULTS.md §1.2 / §7)

```bash
./rvss build/demo1.elf > /dev/null 2>&1; echo "demo1 rc=$?"  # rc=0
./rvss build/demo2.elf > /dev/null 2>&1; echo "demo2 rc=$?"  # rc=0
./rvss build/demo3.elf > /dev/null 2>&1; echo "demo3 rc=$?"  # rc=0
for d in demo1 demo2 demo3; do echo "== $d =="; ./rvss build/$d.elf 2>&1 | grep -E "OUT|retired"; done
./rvss /tmp/llvm_demo.elf 2>&1 | grep -E "retired|exit"   # LLVM kernel: retired 76 exit=0
```

All `rc=0`, `retired` ≈4k (demos) / 76 (LLVM minimal) → matches `TEST_RESULTS.md` tables.

---

## 16. Clean up

```bash
make clean
ls -la   # removes build/ + ai-compiler + rvss
```

---

## 17. Normal Operations vs Custom AI Instructions Operations

This section gives copy-paste **commands containing examples of both**:
(1) **Normal RISC-V operations** (Rocket Chip **RV64IMAFD**) and (2) **Custom AISS AI instructions** (`custom-0` `0x0B`).
Run in order — every command is reproducible from a clean build (`make clean && make`).

### 17.1 Normal Operations — what they are

Standard `RV64IMAFD` (Rocket Chip's unprivileged base ISA) decoded by `rvss.c:299-515`. Groups:

| Group | Examples (normal) | `rvss.c` opcode |
|-------|-------------------|-----------------|
| RV64I base | `add addi sub slli srli srai and or xor slt sltu lui auipc jal jalr beq bne blt bge lb lh lw ld sb sh sw sd fence ecall` | `0x13 0x33 0x37 0x17 0x6F 0x67 0x63 0x03 0x23` |
| RV64M | `mul mulh div rem mulw divw remw` | `0x33 f7=1` |
| RV64A | `amo*` (via `+a`) | — |
| RV64F/D | `flw fsw fld fsd fadd.s fsub.s fmul.s fdiv.s fsqrt.s fmadd.s fmsub.s fsgnj.s fmin.s fmax.s feq.s flt.s fle.s fcvt.s.w fcvt.w.s fmv.w.x fmv.x.w fclass.s` | `0x07 0x27 0x43 0x53` |

Generate and inspect normal scalar lowering (`-O0` = pure normal ops, no `.word`):

```bash
# (a) Trivial C → normal RV64GC ops (addw, ld, sd, ret)
cat > /tmp/trivial.c <<'EOF'
int add(int a,int b){return a+b;}
int main(){return add(2,3);}
EOF
llvm-build/bin/clang --target=riscv64 -march=rv64gc -S -o /tmp/trivial.s /tmp/trivial.c && cat /tmp/trivial.s
llvm-build/bin/clang --target=riscv64 -march=rv64gc -c -o /tmp/trivial.o /tmp/trivial.c && llvm-build/bin/llvm-objdump -d /tmp/trivial.o
# -> addw a0,a0,a1  |  ld ra,8(sp)  |  ret   (all normal RV64I)

# (b) AIIR → normal RV64IMAFD scalar expansion (flw/fadd.s/fsw/fmul.s/fmadd.s loops)
./ai-compiler -O0 -o /tmp/demo1_O0.s demos/demo1.aiir && cat /tmp/demo1_O0.s
./ai-compiler -O0 -o /tmp/demo2_O0.s demos/demo2.aiir && cat /tmp/demo2_O0.s
./ai-compiler -O0 -o /tmp/demo3_O0.s demos/demo3.aiir && cat /tmp/demo3_O0.s
# -> shows: flw fa0,0(t1) / fadd.s fa2,fa0,fa1 / fmul.s / fmadd.s / flt.s / fmv.s / bnez / addi / li / mv / ret

# (c) Disassemble a normal (-O0) ELF — zero custom words, only normal encodings
./ai-compiler -O0 -o /tmp/demo1_sw.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c /tmp/demo1_sw.kernel.s -o /tmp/demo1_sw.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o /tmp/demo1_sw.elf runtime/crt0.s /tmp/demo1_sw.kernel.o runtime/runtime.c runtime/driver.c
riscv64-unknown-elf-objdump -d /tmp/demo1_sw.elf | sed -n '/<ai_kernel>:/,/ret/p' | head -n 80
riscv64-unknown-elf-objdump -d /tmp/demo1_sw.elf | grep -E "14730e0b|14031e0b|14732e0b|14733e0b" && echo "found custom" || echo "no custom words — pure normal ops (expected for -O0)"
grep -c "\.word" /tmp/demo1_sw.kernel.s && echo "custom count" || echo "0 .word (normal-only)"
./rvss /tmp/demo1_sw.elf 2>&1 | grep -E "OUT|retired"  # OUT=[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ] via normal ops
```

Normal-ops-only kernel excerpt (`/tmp/demo1_O0.s`, `ai-compiler.c:92`):

```asm
.Lsw1_2:
        flw     fa0, 0(t1)           # normal RV64F load
        flw     fa1, 0(t2)
        fadd.s  fa2, fa0, fa1        # normal RV64F arithmetic
        fsw     fa2, 0(t3)           # normal RV64F store
        addi    t1, t1, 4            # normal RV64I
        bnez    t0, .Lsw1_2          # normal branch
```

Matmul normal path (`-O0`) uses `fmadd.s`/`mul`/`slli` loops (`ai-compiler.c:132`):

```bash
grep -n "fmadd.s\|fadd.s\|fmul.s\|flw\|fsw" /tmp/demo2_O0.s | head
# fmadd.s ft1, fa0, fa1, ft0  +  mul/slli/add address math
```

### 17.2 Custom AI Instructions — what they are

AISS extension at `custom-0` `opcode=0x0B` `funct7=0x0A` (`docs/riscv-aiss-spec.md:26`, `rvss.c:516`, `ai-compiler.c:47`):

| funct3 | Mnemonic | Encoding `.word` | Operation | `rvss.c` handler |
|-------:|----------|------------------|-----------|------------------|
| 0 | `ai.add`    | `0x14730e0b` | `dst[i]=A[i]+B[i]` | `ai_vadd` `:79` |
| 1 | `ai.relu`   | `0x14031e0b` | `dst[i]=max(0,A[i])` | `ai_vrelu` `:95` |
| 2 | `ai.mul`    | `0x14732e0b` | `dst[i]=A[i]*B[i]` | `ai_vmul` `:87` |
| 3 | `ai.matmul` | `0x14733e0b` | `dst[m,n]=Σ_k A[m,k]*B[k,n]` | `ai_matmul` `:103` |

R-type: `funct7(0x0A) | rs2 | rs1 | funct3 | rd | opcode(0x0B)` with fixed `rd=28(x28/t3) rs1=6(x6/t1) rs2=7(x7/t2)` (`ai-compiler.c:47`). Register ABI: `x5=t0=n`, `x6=t1=A`, `x7=t2=B`, `x28=t3=dst`, `x29=M x30=K x31=N` for matmul.

Generate and inspect custom lowering (`-O1` = custom `.word` + normal prologue/epilogue):

```bash
# (a) AIIR → custom AISS words (one .word per tensor op) + normal moves
./ai-compiler -O1 -o /tmp/demo1_O1.s demos/demo1.aiir && cat /tmp/demo1_O1.s
./ai-compiler -O1 -o /tmp/demo2_O1.s demos/demo2.aiir && cat /tmp/demo2_O1.s
./ai-compiler -O1 -o /tmp/demo3_O1.s demos/demo3.aiir && cat /tmp/demo3_O1.s
grep -n "\.word" /tmp/demo1_O1.s /tmp/demo2_O1.s /tmp/demo3_O1.s
# demo1: 0x14730e0b add, 0x14732e0b mul, 0x14031e0b relu
# demo2: 0x14733e0b matmul
# demo3: 0x14733e0b matmul + 0x14730e0b add + 0x14031e0b relu

# (b) Disassemble built ELFs — custom words appear inline with normal ops
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
riscv64-unknown-elf-objdump -d build/demo1.elf | grep -E "14730e0b|14031e0b|14732e0b|14733e0b"
# 80000030: 14730e0b  .word 0x14730e0b  # ai.add  f3=0
# 80000044: 14732e0b  .word 0x14732e0b  # ai.mul  f3=2
# 80000054: 14031e0b  .word 0x14031e0b  # ai.relu f3=1
riscv64-unknown-elf-objdump -d build/demo2.elf | grep 14733e0b  # ai.matmul f3=3
riscv64-unknown-elf-objdump -d build/demo3.elf | grep -E "14730e0b|14031e0b|14733e0b"

# (c) LLVM XAi path — same bytes via TableGen (RISCVInstrInfoAI.td:37, rvss.c:516)
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"   # -> [0x0b,0x0e,0x73,0x14] = 0x14730e0b
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.relu t3, t1, t2"  # -> 0x14031e0b
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.mul t3, t1, t2"   # -> 0x14732e0b
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.matmul t3, t1, t2" # -> 0x14733e0b
cat > /tmp/ai_intrinsic.ll <<'EOF'
target triple = "riscv64"
declare void @llvm.riscv.ai.add()
declare void @llvm.riscv.ai.relu()
declare void @llvm.riscv.ai.mul()
declare void @llvm.riscv.ai.matmul()
define void @k(){ call void @llvm.riscv.ai.add(); call void @llvm.riscv.ai.relu(); call void @llvm.riscv.ai.mul(); call void @llvm.riscv.ai.matmul(); ret void }
EOF
llvm-build/bin/llc -march=riscv64 -mattr=+xai -o /tmp/ai_intrinsic.s /tmp/ai_intrinsic.ll && cat /tmp/ai_intrinsic.s
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding /tmp/ai_intrinsic.s  # 4× ai.* -> same 4 words

# (d) Python bit-decode proves opcode 0x0B / funct7 0x0A (docs/riscv-aiss-spec.md:24)
python3 <<'PY'
for name,f3,exp in [("ai.add",0,0x14730e0b),("ai.relu",1,0x14031e0b),("ai.mul",2,0x14732e0b),("ai.matmul",3,0x14733e0b)]:
    enc=(0x0A<<25)|(7<<20)|(6<<15)|(f3<<12)|(28<<7)|0x0B
    if f3==1: enc=(0x0A<<25)|(0<<20)|(6<<15)|(f3<<12)|(28<<7)|0x0B
    print(f"{name:9s} f3={f3} -> {enc:#010x} expect {exp:#010x} ok={enc==exp}  opcode={enc&0x7F:#x} f7={(enc>>25)&0x7F:#x}")
PY

# (e) Execute custom ELFs — rvss decodes custom-0 at rvss.c:516
./rvss build/demo1.elf 2>&1 | grep -E "OUT|retired"  # OUT=[3.0 4.0 9.0 ...] 4090 retired (custom)
./rvss build/demo2.elf 2>&1 | grep -E "OUT|retired"  # OUT=[2.0 -4.0 6.0 ...] 4105
./rvss build/demo3.elf 2>&1 | grep -E "OUT|retired"  # OUT=[4.0 0.0 12.0 ...] 4056
```

Custom kernel excerpt (`/tmp/demo1_O1.s`, `ai-compiler.c:121`):

```asm
        li      t0, 8                      # VLEN (x5)
        mv      t1, a0                     # A    (x6) — normal
        mv      t2, a1                     # B    (x7) — normal
        addi    t3, sp, -16                # dst  (x28) — normal
        .word   0x14730e0b                 # ai.add  t3,t1,t2  — CUSTOM (funct3=0)
        li      t0, 8
        addi    t1, sp, -16
        mv      t2, a0
        addi    t3, sp, -80
        .word   0x14732e0b                 # ai.mul  — CUSTOM (funct3=2)
        li      t0, 8
        addi    t1, sp, -80
        addi    t3, sp, -144
        .word   0x14031e0b                 # ai.relu — CUSTOM (funct3=1)
```

### 17.3 Side-by-side: Normal vs Custom lowering of the same AIIR

Same input (`demos/demo1.aiir:9-11` — `ai.add → ai.mul → ai.relu`), two lowerings:

```bash
# Show both side-by-side, prove custom is pure acceleration (bit-exact OUT)
diff -u /tmp/demo1_O0.s /tmp/demo1_O1.s | head -n 80
echo "=== -O0 normal .word count ==="; grep -c "\.word" /tmp/demo1_O0.s || echo 0
echo "=== -O1 custom .word count ==="; grep -c "\.word" /tmp/demo1_O1.s
echo "=== line counts ==="; wc -l /tmp/demo1_O0.s /tmp/demo1_O1.s
# -O0: ~55 lines, 0 .word, scalar flw/fadd.s/fmul.s loops
# -O1: ~32 lines, 3 .word, compact custom ops

# Prove numeric equivalence (HW custom vs SW normal) — both must print identical OUT
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o /tmp/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c /tmp/${d}_sw.kernel.s -o /tmp/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o /tmp/${d}_sw.elf runtime/crt0.s /tmp/${d}_sw.kernel.o runtime/runtime.c runtime/driver.c
  echo "== $d normal (-O0) =="; ./rvss /tmp/${d}_sw.elf 2>&1 | grep OUT
  echo "== $d custom (-O1) =="; ./rvss build/${d}.elf 2>&1 | grep OUT
done
# demo1 OUT=[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]  both
# demo2 OUT=[2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ] both
# demo3 OUT=[4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ] both

# Mixed ELF view — normal + custom interleaved in one ai_kernel
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/^8000.*<.*>:/p' | cat
# li/mv/addi (normal)  →  .word 0x14730e0b (custom)  →  li/addi/mv (normal) → .word 0x14732e0b (custom) → …
```

Summary:

* **Normal operations**: every instruction with `opcode != 0x0B` — `addi/mv/li/flw/fsw/fadd.s/fmul.s/fmadd.s/bnez/ret` etc., emitted by `ai-compiler -O0` (`ai-compiler.c:92,132`) and by `clang --target=riscv64 -march=rv64gc`.
* **Custom operations**: four `custom-0` words `0x14730e0b/0x14031e0b/0x14732e0b/0x14733e0b` (`ai-compiler.c:47`, `docs/riscv-aiss-spec.md:24`, `rvss.c:516`), emitted by `ai-compiler -O1` and by `llvm-mc -mattr=+xai` / `llc -mattr=+xai` / `clang -march=rv64gc_xai` via `RISCVInstrInfoAI.td:37`.

---

## Quick reference (one-liner reproduces TEST_RESULTS.md)

```bash
make clean && make && make test
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"  # -> 0x14730e0b
cat > /tmp/k.ll <<'EOF'
target triple="riscv64"
declare void @llvm.riscv.ai.add()
define void @k(){ call void @llvm.riscv.ai.add(); ret void }
EOF
llvm-build/bin/llc -march=riscv64 -mattr=+xai -o /tmp/k.s /tmp/k.ll && llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding /tmp/k.s
./rvss build/demo1.elf 2>&1 | grep OUT; ./rvss build/demo2.elf 2>&1 | grep OUT; ./rvss build/demo3.elf 2>&1 | grep OUT
```

Expected (matches `TEST_RESULTS.md` §4.5 / §6):
- `llvm-mc` → `[0x0b,0x0e,0x73,0x14]` = `0x14730e0b`
- `llc` → `ai.add` → same bytes
- `demo1 OUT=[3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]`
- `demo2 OUT=[2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]`
- `demo3 OUT=[4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]`
- `make test` 15 PASS
