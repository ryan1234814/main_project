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

99 checks in the demo suite, then a separate 35-case unit campaign. The demo suite covers:
per-demo exit code / header / completion for all **eight** demos, each demo's **own overridden
operands** (`PASS: demoN custom operands A/B`), the exact `OUT` numbers, the `-O0` software
fallback matching the `-O1` AISS-hardware result bit-for-bit, a static audit of every generated
`.s` (`tests/asm-check.py`), and an independent Python model of each kernel including the lanes
the driver never prints plus the operand lines quoted in each `.aiir` header
(`tests/oracle.py`).

Expected output (all PASS, exit code 0):

```
PASS: demo1 exit ok
PASS: demo1 prints header
PASS: demo1 prints done
...  (same three checks for demo2 … demo8)
PASS: demo1 custom operands A
PASS: demo1 custom operands B
PASS: demo1 relu((A+B)*A)
...  (operand + result checks for demo2 … demo8)
PASS: sw demo1 matches hardware
...  (sw/hw parity for demo2 … demo8)
PASS: demo1  3 AI words: encodings, bit fields, register ABI, operand table and -O0 purity all check out
...  (asm-check for demo2 … demo8)
PASS: generated .s files match the AISS encoding and register ABI
PASS: demo1 oracle vs simulator
...  (oracle for demo2 … demo8)
PASS: oracle agrees with simulator for all demos
done.
############ PHASE 1: INDIVIDUAL OPERATIONS ############
...  (add/mul/relu at N=4,8,16, the same three on a 4x4 result type, and matmul
     1x1x1…4x4x4 plus 2x4x2, all hw==sw==ref)
============================================================
UNIT TEST SUMMARY:  35 PASS, 0 FAIL
============================================================
```

---

## 3. Run the demos on the simulated RISC-V chip

```bash
make demo1
make demo2
make demo3
make demo4 demo5 demo6 demo7 demo8
```

Expected output:

```
# demo1   (ai.add -> ai.mul -> ai.relu)
== AISS demo ==
A (operand) = [2.0 -3.0 4.0 -5.0 6.0 -7.0 8.0 -9.0 ]
B (operand) = [10.0 20.0 30.0 40.0 50.0 60.0 70.0 80.0 ]
Running ai_kernel(A, B, OUT) ...
OUT (result) = [24.0 0.0 136.0 0.0 336.0 0.0 624.0 0.0 ]
done

# demo2   (ai.matmul 4x4x4)
A (operand) = [1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 ]
B (operand) = [5.0 0.0 0.0 0.0 0.0 -2.0 0.0 0.0 ]
OUT (result) = [5.0 -4.0 12.0 4.0 25.0 -12.0 28.0 8.0 ]

# demo3   (ai.matmul + ai.add + ai.relu)
A (operand) = [1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 ]
B (operand) = [3.0 0.0 0.0 0.0 0.0 -2.0 0.0 0.0 ]
OUT (result) = [6.0 0.0 6.0 32.0 30.0 0.0 14.0 64.0 ]

# demo4   (ai.relu -> ai.add -> ai.mul)
A (operand) = [-1.0 2.0 -3.0 4.0 -5.0 6.0 -7.0 8.0 ]
B (operand) = [10.0 20.0 30.0 40.0 50.0 60.0 70.0 80.0 ]
OUT (result) = [0.0 44.0 0.0 176.0 0.0 396.0 0.0 704.0 ]

# demo5   (ai.mul -> ai.add -> ai.relu)
A (operand) = [-11.0 12.0 -13.0 14.0 -15.0 16.0 -17.0 18.0 ]
B (operand) = [1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 ]
OUT (result) = [0.0 36.0 0.0 70.0 0.0 112.0 0.0 162.0 ]

# demo6   (ai.matmul -> ai.relu -> ai.add)
A (operand) = [1.0 -2.0 3.0 -4.0 5.0 6.0 -7.0 8.0 ]
B (operand) = [2.0 0.0 0.0 0.0 0.0 3.0 0.0 0.0 ]
OUT (result) = [4.0 0.0 12.0 0.0 10.0 21.0 0.0 40.0 ]

# demo7   (ai.matmul 2x4 @ 4x2 -- C is only 2x2, the driver still prints 8 lanes)
A (operand) = [1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 ]
B (operand) = [1.0 0.0 2.0 0.0 3.0 0.0 4.0 0.0 ]
OUT (result) = [30.0 0.0 70.0 0.0 0.0 0.0 0.0 0.0 ]

# demo8   (same kernel as demo1, own A only -- B stays the driver default)
A (operand) = [10.0 20.0 30.0 -40.0 -50.0 -60.0 70.0 80.0 ]
B (operand) = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]
OUT (result) = [120.0 400.0 900.0 1600.0 2500.0 3480.0 4900.0 6400.0 ]
```

Note that **the operands differ per demo**: each `.aiir` carries its own
`; @operands: 0x444F5031 ...` line, which `ai-compiler` emits as a weak
`demo_operands` table and `driver.c` copies over its defaults (slots 0-15 -> A,
16-31 -> B). The numbers for demo4-demo8, and the results they must produce, are
tabulated in `files.md` section 4 and repeated in the header comment of each
`.aiir`; `tests/oracle.py` checks both against the real output on `make test`.

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
RVSS_AI_TRACE=1 ./rvss build/demo1.elf      # print each AI op's inputs + output (intermediate steps)
RVSS_TRACE=1 ./rvss build/demo1.elf          # dump last 256 instructions on error
RVSS_MAX=100000 ./rvss build/demo1.elf       # cap the instruction budget
RVSS_BRK=0x80000020 ./rvss build/demo1.elf   # dump all registers when PC == address
RVSS_WATCH=1 ./rvss build/demo1.elf          # trace stores into stack/OUT region
RVSS_FMA=1 ./rvss build/demo2_sw.elf         # trace FP-multiply-accumulate ops
```

(`RVSS_AI_TRACE` decodes the custom AI words, so it works on the `-O1` hardware ELFs; the
`-O0` software ELFs have no custom words to decode. `bash tests/unit/show.sh <case> hw trace`
wraps it with a labelled banner.)

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

This kernel has **no** `; @operands:` line, so it falls back to `driver.c`'s
stock `A = [1,-2,3,-4,...]` and `B = 2·Identity`; that is why its answer differs
from `demo1`, which runs the same chain on its own numbers.

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
