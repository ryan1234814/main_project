# Setup & Test Guide — AISS demo

One-time requirements (already present on this machine):

* `cc` (any host C compiler)
* `make`
* `riscv64-unknown-elf-gcc` (RISC-V cross-compiler, e.g. via
  `brew install riscv-gnu-toolchain`)

All commands below are run from the project root.

> **Target ISA:** every binary is built for the open-source **Rocket Chip** core's
> **RV64IMAFD** unprivileged ISA (`-march=rv64imafd -mabi=lp64`), with the four AISS
> AI instructions layered on in the RISC-V `custom-0` opcode space.

---

## 1. Build everything (incl. LLVM XAi backend — optional but verified)

```bash
make clean
make
```

This builds:

* `ai-compiler` — the AI-dialect compiler (host binary)
* `rvss` — the RISC-V ISA simulator (host binary)
* `build/demo1.elf`, `build/demo2.elf`, `build/demo3.elf` — the demo kernels
  compiled for RISC-V (`-march=rv64imafd -mabi=lp64 -mcmodel=medany`)

The **LLVM XAi backend** is already built at `llvm-build/bin/clang|llc|llvm-mc` (Release, `RISCV` only, `XAi` at `llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td` / `llvm/IR/IntrinsicsRISCV.td`). To rebuild it from source (as in `TEST_RESULTS.md` §1):

```bash
cmake -S llvm/llvm -B llvm-build -G Ninja -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD="RISCV" -DCMAKE_BUILD_TYPE=Release
ninja -C llvm-build -j8 clang llc llvm-mc llvm-objdump   # <2 min incremental
llvm-build/bin/llc --version   # must list riscv64
llvm-build/bin/llvm-mc -mattr=help | grep xai
```

---

## 2. Run the full test suite

```bash
make test
```

15 checks: per-demo exit code / header / completion, exact numeric results for
all three demos, **and** the `-O0` software fallback of every demo matching the
`-O1` AISS-hardware result bit-for-bit.

Expected output (all PASS, exit code 0):

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

---

## 3. Run the demos on the simulated RISC-V chip

```bash
make demo1
make demo2
make demo3
```

Expected output:

```
# demo1   (ai.add -> ai.mul -> ai.relu)
== AISS demo ==
A = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ]
B = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]
OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]
done

# demo2   (ai.matmul 4x4x4)
OUT = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]   # 2 × A

# demo3   (ai.matmul + ai.add + ai.relu)
OUT = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]        # relu(4 × A)
```

Each run ends with `[rvss] retired N instructions, exit=0` — exit code 0 and
`rc=0` mean success. Verify explicitly:

```bash
./rvss build/demo1.elf > /dev/null 2>&1; echo "rc=$?"    # rc=0
```

---

## 4. Compile one demo by hand (shows every pipeline stage)

```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -Wall \
    -T runtime/riscv64.ld -nostdlib -static \
    -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o \
    runtime/runtime.c runtime/driver.c
./rvss build/demo1.elf
```

---

## 5. Software-fallback path (same AI ops **without** AI hardware)

Compile with `-O0`: every AI op becomes plain RV64IMAFD scalar loops. The
numeric results must be identical to the hardware path — this proves the
custom instructions are a pure *acceleration* of the basic-instruction path.

```bash
for d in demo1 demo2 demo3; do
  ./ai-compiler -O0 -o build/${d}_sw.kernel.s demos/${d}.aiir
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax \
      -c build/${d}_sw.kernel.s -o build/${d}_sw.kernel.o
  riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 \
      -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
      -o build/${d}_sw.elf runtime/crt0.s build/${d}_sw.kernel.o \
      runtime/runtime.c runtime/driver.c
  echo "== $d (software) =="; ./rvss build/${d}_sw.elf
done
```

Expected: the `OUT = [...]` lines match the demo results in §3 exactly.

---

## 6. Inspect the custom AI instructions in the binary (standalone vs LLVM)

```bash
# raw .word custom-0 encodings in the generated assembly (standalone ai-compiler)
grep -n "\.word" build/demo1.kernel.s build/demo2.kernel.s build/demo3.kernel.s

# and in the linked binary (objdump shows them as .word, not mnemonics)
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
# LLVM XAi path — same bytes via llvm-mc / llc
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
# -> [0x0b,0x0e,0x73,0x14] = 0x14730e0b
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.matmul t3, t1, t2"
# -> [0x0b,0x3e,0x73,0x14] = 0x14733e0b
```

You will see `0x…0b` words — `custom-0` (`0x0B`) AISS instructions
(`ai.add` / `ai.mul` / `ai.relu` / `ai.matmul`) executed by the simulator's
AI unit. Cross-check an encoding against `docs/riscv-aiss-spec.md` (now with XAi LLVM mapping):

```bash
riscv64-unknown-elf-objdump -d build/demo1.elf | grep -m1 "\.word\|0x14730e0b"
# 0x14730e0b = funct7 0x0A | funct3 0 (ai.add) | opcode 0x0B  (standalone and LLVM XAi identical)
```

---

## 7. Simulator debug / inspection switches

```bash
RVSS_TRACE=1 ./rvss build/demo1.elf          # dump last 256 instructions on error
RVSS_MAX=100000 ./rvss build/demo1.elf       # cap the instruction budget
RVSS_BRK=0x80000020 ./rvss build/demo1.elf   # dump all registers when PC == address
RVSS_WATCH=1 ./rvss build/demo1.elf          # trace stores into stack/OUT region
RVSS_FMA=1 ./rvss build/demo2_sw.elf         # trace FP-multiply-accumulate ops
```

(`RVSS_FMA` is most useful on a `-O0` build, which uses scalar FP loops.)

---

## 8. Write and run your own AI kernel

```bash
cat > demos/my_kernel.aiir <<'EOF'
; relu((A + B) * A) — elementwise on two 8xf32 inputs
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %3 = "ai.mul"(%2, %0)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %4 = "ai.relu"(%3)     : (tensor<8xf32>) -> tensor<8xf32>
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
EOF

./ai-compiler -O1 -o build/my_kernel.kernel.s demos/my_kernel.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/my_kernel.kernel.s -o build/my_kernel.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
    -o build/my_kernel.elf runtime/crt0.s build/my_kernel.kernel.o \
    runtime/runtime.c runtime/driver.c
./rvss build/my_kernel.elf        # must print OUT = [3.0 4.0 9.0 16.0 ...]
```

---

## 9. ISA / disassembly archaeology

```bash
# full disassembly of a demo
riscv64-unknown-elf-objdump -d build/demo1.elf | less

# all custom-0 encodings (funct7=0x0A) actually present in a binary
riscv64-unknown-elf-objdump -d build/demo3.elf | grep -E "\.word" 

# instruction mix: how many basic vs custom instructions retire
RVSS_TRACE=1 ./rvss build/demo1.elf 2>&1 | grep -c "0x8000" 
```

---

## 10. Clean up

```bash
make clean      # removes build/ plus the two host binaries
```
