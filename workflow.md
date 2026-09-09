# Workflow — Beginner Guide: AISS RISC-V AI-Instruction Compiler + Simulator

> **Project:** AISS — a tiny RISC-V AI-instruction compiler + ISA simulator demo  
> **Goal:** Learn end-to-end how custom AI instructions are added to RISC-V, compiled from an MLIR-like language, and executed on a simulated chip.

This document explains the **entire project from zero to finish** in beginner-friendly language, with **exact terminal commands** to run at every stage. Copy-paste each block in order.

---

## Table of Contents

1. [Big Picture — What Are We Building?](#1-big-picture--what-are-we-building)
2. [Concepts for Absolute Beginners](#2-concepts-for-absolute-beginners)
3. [Repository Layout](#3-repository-layout)
4. [Prerequisites — Check Your Machine](#4-prerequisites--check-your-machine)
5. [Stage 0 — Get the Code and Enter the Project](#5-stage-0--get-the-code-and-enter-the-project)
6. [Stage 1 — Understand the Input Language (.aiir)](#6-stage-1--understand-the-input-language-aiir)
7. [Stage 2 — Build the Host Tools (ai-compiler + rvss)](#7-stage-2--build-the-host-tools-ai-compiler--rvss)
8. [Stage 3 — Compile Demos (AI IR → RISC-V Assembly → ELF)](#8-stage-3--compile-demos-ai-ir--risc-v-assembly--elf)
9. [Stage 4 — Run Demos on the Simulated RISC-V Chip](#9-stage-4--run-demos-on-the-simulated-risc-v-chip)
10. [Stage 5 — Inspect What the Compiler Generated](#10-stage-5--inspect-what-the-compiler-generated)
11. [Stage 6 — Compare Hardware Path (-O1) vs Software Fallback (-O0)](#11-stage-6--compare-hardware-path--o1-vs-software-fallback--o0)
12. [Stage 7 — Run the Full Test Suite](#12-stage-7--run-the-full-test-suite)
13. [Stage 8 — Write and Run Your Own AI Kernel](#13-stage-8--write-and-run-your-own-ai-kernel)
14. [Stage 9 — Debugging and Inspection Tricks](#14-stage-9--debugging-and-inspection-tricks)
15. [Stage 10 — Clean Up and Optional Full LLVM Build](#15-stage-10--clean-up-and-optional-full-llvm-build)
16. [End-to-End Command Cheat Sheet](#16-end-to-end-command-cheat-sheet)
17. [Troubleshooting](#17-troubleshooting)

---

## 1. Big Picture — What Are We Building?

```
Your AI Idea (math)
        |
        v
  .aiir file (MLIR-flavoured text, e.g., "add two tensors, multiply, relu")
        |
        v
  ai-compiler  --O1-->  RISC-V assembly with CUSTOM AI instructions (.word 0x...0B)
               --O0-->  RISC-V assembly with NORMAL instructions only (scalar loops)
        |
        v
  riscv64-unknown-elf-gcc (cross-compiler) + runtime (crt0.s, driver.c, runtime.c)
        |
        v
  Bare-metal ELF binary (runs at RAM 0x80000000, no OS)
        |
        v
  rvss (RISC-V simulator) — executes the ELF, decodes custom-0 instructions on a simulated AI unit
        |
        v
  Prints OUT = [ ... ] on your terminal
```

**Why this matters:** Real AI chips (Google TPU, etc.) do exactly this — add custom instructions to a CPU, build a compiler that emits them, and simulate them before making silicon. This project is a minimal, runnable version of that flow.

---

## 2. Concepts for Absolute Beginners

| Term | Simple Meaning |
|------|----------------|
| **RISC-V** | An open-source CPU instruction set (like x86/ARM but free). `RV64IMAF` means 64-bit + Multiply + Float support. |
| **ISA (Instruction Set Architecture)** | The vocabulary a CPU understands. We add 4 new words: `ai.add`, `ai.relu`, `ai.mul`, `ai.matmul`. |
| **custom-0 opcode (0x0B)** | A blank space RISC-V reserves for you to add your own instructions. Our 4 AI ops live there with `funct7=0x0A`. |
| **MLIR / .aiir** | A way to write AI math as text. Example: `%2 = "ai.add"(%0, %1)` means add two 8-element tensors. |
| **ai-compiler** | A ~600-line C program that reads `.aiir` and writes RISC-V assembly (`.s`). No LLVM install needed. |
| **rvss** | RISC-V System Simulator — a C program that pretends to be a RISC-V chip and runs your binary. |
| **Cross-compiler (`riscv64-unknown-elf-gcc`)** | A compiler that runs on your Mac/PC but produces code for RISC-V (not for your host CPU). |
| **Bare-metal / ELF** | No Linux. The binary runs directly on simulated RAM at `0x80000000`. `crt0.s` sets up stack pointer, `runtime.c` handles printing. |
| **tohost semihosting** | How the simulated chip talks to your computer: writes to a magic memory address `tohost` to print or exit. |
| **-O1 vs -O0** | `-O1` = use custom AI hardware (one `.word` instruction does 8 or 16 floats at once). `-O0` = use normal scalar loops. Both give same numeric answer. |

**The 4 custom instructions:**

| Instruction | What it does | Registers used |
|-------------|--------------|----------------|
| `ai.add` (funct3=0) | `dst[i] = A[i] + B[i]` for `n` elements | `x5=n, x6=A, x7=B, x28=dst` |
| `ai.relu` (funct3=1) | `dst[i] = max(0, A[i])` | `x5=n, x6=A, x28=dst` |
| `ai.mul` (funct3=2) | `dst[i] = A[i] * B[i]` | `x5=n, x6=A, x7=B, x28=dst` |
| `ai.matmul` (funct3=3) | `C = A @ B` matrix multiply | `x6=A, x7=B, x28=C, x29=M, x30=K, x31=N` |

---

## 3. Repository Layout

```
.
├── ai-compiler.c        # Compiler: .aiir → RISC-V assembly (host binary after build)
├── rvss.c               # Simulator: runs ELF, decodes RV64IMAF + 4 AI ops (host binary after build)
├── runtime/
│   ├── crt0.s           # Startup: sets gp/sp, calls main()
│   ├── riscv64.ld       # Linker script: RAM at 0x80000000, stack at top
│   ├── runtime.c        # tohost print/exit helpers
│   └── driver.c         # main() that feeds A,B arrays into ai_kernel() and prints OUT
├── demos/
│   ├── demo1.aiir       # relu((A+B)*A) — tests add/mul/relu
│   ├── demo2.aiir       # 4x4 matmul — tests ai.matmul
│   └── demo3.aiir       # relu((W·x)+(W·x)) — tests matmul+add+relu chain
├── build/               # Generated files (.s, .o, .elf) — created by make
├── Makefile             # Builds everything, runs demos/tests
├── build-llvm.sh        # Optional: builds full LLVM 18.1.8 with MLIR (not needed for demo)
├── docs/
│   └── riscv-aiss-spec.md  # Formal spec for the 4 custom instructions
├── architecture.md      # Block diagrams & microarchitecture spec
├── setup.md             # Concise command reference
├── TEST_RESULTS.md      # Expected test outputs
└── tests/run-tests.sh   # 15 automated checks
```

---

## 4. Prerequisites — Check Your Machine

You need three tools on your host (Mac/Linux):

| Tool | Purpose | How to check |
|------|---------|--------------|
| `cc` or `clang` | Compile `ai-compiler` and `rvss` for your host | `cc --version` |
| `make` | Run the Makefile | `make --version` |
| `riscv64-unknown-elf-gcc` | Cross-compile RISC-V assembly → ELF | `riscv64-unknown-elf-gcc --version` |

**Terminal commands — Stage 4a: Verify prerequisites:**

```bash
# 1. Check host C compiler
cc --version

# 2. Check make
make --version

# 3. Check RISC-V cross-compiler (most important)
riscv64-unknown-elf-gcc --version

# 4. Check you are in the project root (should list Makefile, ai-compiler.c, etc.)
pwd
ls -la
# Expected: Makefile, ai-compiler.c, rvss.c, demos/, runtime/, docs/ ...

# If riscv64-unknown-elf-gcc is missing on macOS:
brew install riscv-gnu-toolchain
# On Ubuntu/Debian:
# sudo apt-get install gcc-riscv64-unknown-elf
```

> **Note:** If `riscv64-unknown-elf-gcc` is not found, none of the later stages will work. Install it first.

---

## 5. Stage 0 — Get the Code and Enter the Project

```bash
# If you have not cloned yet (replace URL with actual repo URL)
git clone <repo-url> llvm
cd llvm

# Or if you already have the folder at ~/llvm
cd ~/llvm
# or on this machine:
cd /Users/ryangeorge/llvm

# Confirm location
pwd
ls -l
cat README.md | head -n 20
```

---

## 6. Stage 1 — Understand the Input Language (.aiir)

Before compiling, look at what you are compiling.

**Terminal commands — Stage 1: Inspect demo inputs:**

```bash
# View all three demo programs
cat demos/demo1.aiir
cat demos/demo2.aiir
cat demos/demo3.aiir

# Check what inputs driver.c feeds into the kernel
cat runtime/driver.c

# Check bare-metal startup and linker
cat runtime/crt0.s
cat runtime/riscv64.ld

# Read the ISA spec (what the 4 custom instructions mean)
cat docs/riscv-aiss-spec.md

# Read architecture diagrams
cat architecture.md | head -n 100
```

**What demo1.aiir means line-by-line:**

```mlir
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>  # add A+B
  %3 = "ai.mul"(%2, %0)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>  # multiply (A+B)*A
  %4 = "ai.relu"(%3)     : (tensor<8xf32>) -> tensor<8xf32>                # relu = max(0, x)
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
```

> Think of `%0` as `A`, `%1` as `B`. The compiler will turn each `ai.*` line into either one custom instruction (`-O1`) or a scalar loop (`-O0`).

---

## 7. Stage 2 — Build the Host Tools (ai-compiler + rvss)

These two C files compile to **native binaries that run on your Mac/PC** (not RISC-V).

**Terminal commands — Stage 2:**

```bash
# Clean any old build artifacts
make clean

# Build both host tools (ai-compiler and rvss)
# This runs: cc -O2 -Wall -o ai-compiler ai-compiler.c
#            cc -O2 -Wall -o rvss rvss.c
make ai-compiler
make rvss

# Verify they were created and are executable
ls -lh ai-compiler rvss
file ai-compiler rvss

# Check compiler help
./ai-compiler 2>&1 || true
# Expected: usage: ai-compiler [-O0|-O1] -o out.s in.aiir

# Check simulator help
./rvss 2>&1 || true
# Expected: usage: rvss <elf>
```

**What happens:**
* `ai-compiler.c` → `ai-compiler` (your host compiler for AI dialect)
* `rvss.c` → `rvss` (your RISC-V chip simulator)

---

## 8. Stage 3 — Compile Demos (AI IR → RISC-V Assembly → ELF)

This is the **core pipeline**: `.aiir` → `.s` → `.o` → `.elf`

```
demos/demo1.aiir --[ai-compiler -O1]--> build/demo1.kernel.s --[riscv64-unknown-elf-gcc -c]--> build/demo1.kernel.o --[gcc link with crt0.s+runtime.c+driver.c]--> build/demo1.elf
```

**Terminal commands — Stage 3: One-step build (recommended):**

```bash
# Build everything at once: host tools + all 3 demos
make clean && make

# List what was generated
ls -lh build/
# Expected:
# build/demo1.kernel.s  (RISC-V assembly)
# build/demo1.kernel.o  (object file)
# build/demo1.elf       (final bare-metal ELF)
# ... same for demo2, demo3

# Look at the generated assembly (notice .word custom-0 instructions)
cat build/demo1.kernel.s
cat build/demo2.kernel.s
cat build/demo3.kernel.s

# Filter just the custom instructions
grep -n "\.word" build/demo1.kernel.s build/demo2.kernel.s build/demo3.kernel.s
```

**Terminal commands — Stage 3: Manual step-by-step for one demo (learning):**

```bash
# Step 3a: AI dialect -> RISC-V assembly (hardware path -O1)
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
cat build/demo1.kernel.s

# Step 3b: RISC-V assembly -> object file
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/demo1.kernel.s -o build/demo1.kernel.o
ls -lh build/demo1.kernel.o

# Step 3c: Link object + runtime into bare-metal ELF
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -Wall \
    -T runtime/riscv64.ld -nostdlib -static \
    -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o \
    runtime/runtime.c runtime/driver.c
ls -lh build/demo1.elf
file build/demo1.elf
# Expected: ELF 64-bit LSB executable, UCB RISC-V ...

# Step 3d: Check ELF sections (where code lands in RAM)
riscv64-unknown-elf-objdump -h build/demo1.elf | head -n 30
riscv64-unknown-elf-readelf -l build/demo1.elf | head -n 40
```

---

## 9. Stage 4 — Run Demos on the Simulated RISC-V Chip

The `rvss` simulator loads the ELF into simulated RAM at `0x80000000` and executes it instruction-by-instruction.

**Inputs are fixed in `runtime/driver.c`:**
```
A[16] = 1,-2,3,-4,5,-6,7,-8,9,10,11,12,13,14,15,16
B[16] = 2 0 0 0 / 0 2 0 0 / 0 0 2 0 / 0 0 0 2   (2×identity)
```

**Terminal commands — Stage 4:**

```bash
# Run each demo individually (via Makefile shortcut)
make demo1
make demo2
make demo3

# Or run directly with rvss
./rvss build/demo1.elf
./rvss build/demo2.elf
./rvss build/demo3.elf

# Check exit code (0 = success)
./rvss build/demo1.elf > /dev/null 2>&1; echo "rc=$?"
# Expected: rc=0

# Run all and capture output
./rvss build/demo1.elf 2>&1
./rvss build/demo2.elf 2>&1
./rvss build/demo3.elf 2>&1
```

**Expected outputs:**

```bash
# demo1: ai.add -> ai.mul -> ai.relu  => relu((A+B)*A)
# == AISS demo ==
# A = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ]
# B = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]
# OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]
# done
# [rvss] retired N instructions, exit=0

# demo2: ai.matmul 4x4 (2 * A because B = 2*I)
# OUT = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]

# demo3: ai.matmul + ai.add + ai.relu => relu(4*A)
# OUT = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]
```

---

## 10. Stage 5 — Inspect What the Compiler Generated

Learn to see the custom instructions inside the binary.

**Terminal commands — Stage 5:**

```bash
# 5a: See .word encodings in assembly
grep -n "\.word" build/demo1.kernel.s
grep -n "\.word" build/demo2.kernel.s
grep -n "\.word" build/demo3.kernel.s

# 5b: Disassemble the kernel function (shows .word where AI ops are)
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
riscv64-unknown-elf-objdump -d build/demo2.elf | sed -n '/<ai_kernel>:/,/ret/p'

# 5c: Full disassembly with less (press q to quit)
riscv64-unknown-elf-objdump -d build/demo1.elf | less

# 5d: Verify an encoding manually (0x14730e0b = ai.add)
# funct7=0x0A, funct3=0, opcode=0x0B
riscv64-unknown-elf-objdump -d build/demo1.elf | grep -E "\.word|14730e0b"

# 5e: Makefile shortcut to dump disassembly
make dump-demo1   # same as objdump -d | less
```

**Decoding example:**
```
0x1c73eb0b = custom-0 (0x0B) + funct7=0x0A + funct3=3 → ai.matmul
0x14730e0b = custom-0 (0x0B) + funct7=0x0A + funct3=0 → ai.add
0x14031e0b = custom-0 (0x0B) + funct7=0x0A + funct3=1 → ai.relu
```

---

## 11. Stage 6 — Compare Hardware Path (-O1) vs Software Fallback (-O0)

Both paths must give **bit-identical** results. `-O0` uses only normal RISC-V float ops (`flw`, `fadd.s`, `fmul.s`, `fmadd.s`).

**Terminal commands — Stage 6:**

```bash
# 6a: Compile demo1 with BOTH paths and compare assembly sizes
./ai-compiler -O1 -o build/demo1_hw.kernel.s demos/demo1.aiir
./ai-compiler -O0 -o build/demo1_sw.kernel.s demos/demo1.aiir
echo "=== Hardware (-O1) ===" && cat build/demo1_hw.kernel.s
echo "=== Software (-O0) ===" && cat build/demo1_sw.kernel.s
wc -l build/demo1_hw.kernel.s build/demo1_sw.kernel.s
# Software file is much longer (loops vs single .word)

# Count custom instructions in each
echo "HW custom ops:" && grep -c "\.word" build/demo1_hw.kernel.s
echo "SW custom ops:" && grep -c "\.word" build/demo1_sw.kernel.s
# Expected: HW=3, SW=0

# 6b: Build and run BOTH ELFs, compare numeric output (should be identical)
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o build/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
      -c build/${d}_sw.kernel.s -o build/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
      -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
      -o build/${d}_sw.elf runtime/crt0.s build/${d}_sw.kernel.o \
      runtime/runtime.c runtime/driver.c
  echo "== $d hardware (-O1) ==" && ./rvss build/${d}.elf 2>&1 | grep "OUT"
  echo "== $d software (-O0) ==" && ./rvss build/${d}_sw.elf 2>&1 | grep "OUT"
done

# 6c: One-liner from setup.md for all three
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o build/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
      -c build/${d}_sw.kernel.s -o build/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
      -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
      -o build/${d}_sw.elf runtime/crt0.s build/${d}_sw.kernel.o \
      runtime/runtime.c runtime/driver.c
  echo "== $d (software) =="; ./rvss build/${d}_sw.elf
done
```

---

## 12. Stage 7 — Run the Full Test Suite

The test suite runs 15 checks: exit codes, printed headers, exact numeric results, and hardware-vs-software equivalence.

**Terminal commands — Stage 7:**

```bash
# Build + test (the main verification)
make test

# Or run the script directly with more verbosity
bash tests/run-tests.sh

# Inspect what the test script does
cat tests/run-tests.sh

# Expected output (all PASS):
# PASS: demo1 exit ok
# PASS: demo1 prints header
# PASS: demo1 prints done
# PASS: demo2 exit ok
# PASS: demo2 prints header
# PASS: demo2 prints done
# PASS: demo3 exit ok
# PASS: demo3 prints header
# PASS: demo3 prints done
# PASS: demo1 relu((A+B)*A)
# PASS: demo2 ai.matmul 4x4
# PASS: demo3 matmul+add+relu
# PASS: sw demo1 matches hardware
# PASS: sw demo2 matches hardware
# PASS: sw demo3 matches hardware
# done.
```

---

## 13. Stage 8 — Write and Run Your Own AI Kernel

Create a new `.aiir` file and run it through the full pipeline.

**Terminal commands — Stage 8:**

```bash
# 8a: Create a new kernel file (example: same as demo1 but you can edit)
cat > demos/my_kernel.aiir <<'EOF'
; my_kernel.aiir — relu((A + B) * A) elementwise on 8xf32
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %3 = "ai.mul"(%2, %0)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %4 = "ai.relu"(%3)     : (tensor<8xf32>) -> tensor<8xf32>
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
EOF
cat demos/my_kernel.aiir

# 8b: Compile it (hardware path)
./ai-compiler -O1 -o build/my_kernel.kernel.s demos/my_kernel.aiir
cat build/my_kernel.kernel.s

# 8c: Assemble
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/my_kernel.kernel.s -o build/my_kernel.kernel.o

# 8d: Link with the same runtime/driver (uses same A,B inputs)
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
    -o build/my_kernel.elf runtime/crt0.s build/my_kernel.kernel.o \
    runtime/runtime.c runtime/driver.c

# 8e: Run it (should match demo1: OUT = [3.0 4.0 9.0 16.0 ...])
./rvss build/my_kernel.elf

# 8f: Try a matmul example (4x4)
cat > demos/my_matmul.aiir <<'EOF'
ai.func @main(%0: tensor<4x4xf32>, %1: tensor<4x4xf32>) -> tensor<4x4xf32> {
  %2 = "ai.matmul"(%0, %1) : (tensor<4x4xf32>, tensor<4x4xf32>) -> tensor<4x4xf32>
  ai.return %2 : tensor<4x4xf32>
}
ai.entry @main
EOF
./ai-compiler -O1 -o build/my_matmul.kernel.s demos/my_matmul.aiir
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/my_matmul.kernel.s -o build/my_matmul.kernel.o
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
    -o build/my_matmul.elf runtime/crt0.s build/my_matmul.kernel.o \
    runtime/runtime.c runtime/driver.c
./rvss build/my_matmul.elf
```

**Tips for writing your own kernel:**
* Only these ops are supported: `ai.add`, `ai.mul`, `ai.relu`, `ai.matmul`, `arith.constant`, `arith.addf`, `arith.mulf`, `ai.return`
* Tensor sizes: max 8 or 16 f32 for elementwise, max 4×4 for matmul (see `ai-compiler.c:MAX_T`)
* Always end with `ai.return %X : tensor<...>` and `ai.entry @main`

---

## 14. Stage 9 — Debugging and Inspection Tricks

**Terminal commands — Stage 9:**

```bash
# 9a: Trace last 256 instructions on abnormal exit
RVSS_TRACE=1 ./rvss build/demo1.elf

# 9b: Cap instruction budget (kill infinite loops early)
RVSS_MAX=100000 ./rvss build/demo1.elf

# 9c: Dump registers when PC hits a specific address (find address via objdump)
riscv64-unknown-elf-objdump -d build/demo1.elf | grep "<ai_kernel>"
# Suppose ai_kernel is at 0x80000020:
RVSS_BRK=0x80000020 ./rvss build/demo1.elf 2>&1 | head -n 40

# 9d: Watch stores into stack/OUT region (debug memory writes)
RVSS_WATCH=1 ./rvss build/demo1.elf 2>&1 | head -n 60

# 9e: Trace FP multiply-accumulate (useful for -O0 software matmul)
RVSS_FMA=1 ./rvss build/demo2_sw.elf 2>&1 | head -n 60

# 9f: Count how many instructions retired
./rvss build/demo1.elf 2>&1 | grep "retired"
./rvss build/demo1_sw.elf 2>&1 | grep "retired"
# Hardware path retires far fewer instructions!

# 9g: Manually check disassembly for illegal instructions
riscv64-unknown-elf-objdump -d build/demo1.elf > /tmp/dump.txt
cat /tmp/dump.txt | head -n 80

# 9h: Check that tohost symbol exists (for semihosting)
riscv64-unknown-elf-nm build/demo1.elf | grep tohost
```

---

## 15. Stage 10 — Clean Up and Optional Full LLVM Build

**Terminal commands — Stage 10a: Clean:**

```bash
# Remove all generated files (build/ + host binaries)
make clean
ls -la
# build/ should be gone, ai-compiler and rvss removed

# Rebuild from scratch to verify reproducibility
make clean && make && make test
```

**Terminal commands — Stage 10b: Optional full LLVM+MLIR build (not required for demo):**

The script `build-llvm.sh` downloads and builds LLVM 18.1.8 with MLIR and RISC-V target. This takes **30–90 minutes** and ~10 GB disk. Only needed if you want to migrate the `.aiir` dialect to real MLIR.

```bash
# Inspect the script first
cat build-llvm.sh

# Run it (long! do in a screen/tmux)
bash build-llvm.sh
# Steps:
# [1/4] Downloading LLVM 18.1.8 tarball
# [2/4] Extracting...
# [3/4] Configuring (Release, MLIR, host+RISCV)
# [4/4] Building with -j10 ...

# Verify build
ls -lh build-rel/bin/mlir-opt 2>&1 | head
ls -lh build-rel/bin/llc 2>&1 | head
```

---

## 16. End-to-End Command Cheat Sheet

Copy-paste this entire block for a **full run from scratch**:

```bash
# === 0. Enter project ===
cd /Users/ryangeorge/llvm
pwd && ls -la

# === 1. Verify tools ===
cc --version
make --version
riscv64-unknown-elf-gcc --version

# === 2. Build host tools + demos ===
make clean
make
ls -lh build/ ai-compiler rvss

# === 3. Run demos (hardware path -O1) ===
make demo1
make demo2
make demo3

# Or individually:
./rvss build/demo1.elf
./rvss build/demo2.elf
./rvss build/demo3.elf

# === 4. Inspect generated assembly ===
grep -n "\.word" build/demo*.kernel.s
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'

# === 5. Software fallback (-O0) — should match ===
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o build/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
      -c build/${d}_sw.kernel.s -o build/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
      -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
      -o build/${d}_sw.elf runtime/crt0.s build/${d}_sw.kernel.o \
      runtime/runtime.c runtime/driver.c
  echo "== $d software =="; ./rvss build/${d}_sw.elf 2>&1 | grep -E "OUT|retired"
done

# === 6. Full test suite ===
make test

# === 7. Manual single-demo pipeline (demo1 as example) ===
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -Wall \
    -T runtime/riscv64.ld -nostdlib -static \
    -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o \
    runtime/runtime.c runtime/driver.c
./rvss build/demo1.elf

# === 8. Debug ===
RVSS_TRACE=1 ./rvss build/demo1.elf 2>&1 | tail -n 30
riscv64-unknown-elf-objdump -d build/demo1.elf | less

# === 9. Clean ===
make clean
```

---

## 17. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `riscv64-unknown-elf-gcc: command not found` | Cross-compiler not installed | `brew install riscv-gnu-toolchain` (macOS) or `apt-get install gcc-riscv64-unknown-elf` |
| `ai-compiler: error: no ai.return found` | `.aiir` missing return statement | Add `ai.return %X : tensor<...>` and `ai.entry @main` |
| `rvss: illegal insn ... op=0x...` | Assembly used compressed (`-mrelax`) or illegal FP | Rebuild with `-mno-relax -march=rv64imaf` |
| `rvss: load fault @0x...` | Out-of-bounds RAM access (tensor >16 elements) | Reduce tensor size, check dims |
| `OUT = [0.0 0.0 ...]` wrong numbers | B tensor not identity or A/B swapped | Check `runtime/driver.c` A/B initialization |
| `make: *** No rule to make target 'build/...'` | `build/` missing | `mkdir -p build` or `make clean && make` |
| `RVSS_TRACE` shows many `0x8000...` | Normal — that is RAM base `0x80000000` | Not an error |

---

## Quick Reference Card

```
.aiir  ──ai-compiler -O1──>  .s (+.word custom-0)  ──gcc -c──>  .o  ──gcc link──>  .elf  ──rvss──>  OUT
       ──ai-compiler -O0──>  .s (scalar loops)    ──gcc -c──>  .o  ──gcc link──>  .elf  ──rvss──>  OUT (same!)
```

**Key files to read in order:** `README.md` → `setup.md` → `docs/riscv-aiss-spec.md` → `architecture.md` → `ai-compiler.c:1-60` → `rvss.c:1-60` → `demos/demo1.aiir` → `Makefile`

*Generated for the AISS project at `/Users/ryangeorge/llvm` — see `README.md:1` and `setup.md:1` for canonical references.*
