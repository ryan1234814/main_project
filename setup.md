# Setup & Test Guide — AISS demo

One-time requirements (already present on this machine):

* `cc` (any host C compiler)
* `make`
* `riscv64-unknown-elf-gcc` (RISC-V cross-compiler, e.g. via
  `brew install riscv-gnu-toolchain`)

All commands below are run from the project root.

---

## 1. Build everything

```bash
make clean
make
```

This builds:

* `ai-compiler` — the AI-dialect compiler (host binary)
* `rvss` — the RISC-V ISA simulator (host binary)
* `build/demo1.elf`, `build/demo2.elf`, `build/demo3.elf` — the demo kernels
  compiled for RISC-V (`-march=rv64imaf -mabi=lp64 -mcmodel=medany`)

---

## 2. Compile one demo by hand (shows every pipeline stage)

```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -Wall \
    -T runtime/riscv64.ld -nostdlib -static \
    -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o \
    runtime/runtime.c runtime/driver.c
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
# demo1
== AISS demo ==
A = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ]
B = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]
OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]
done

# demo2
OUT = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]   # 2 × A

# demo3
OUT = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]        # relu(4 × A)
```

Each run ends with `[rvss] retired N instructions, exit=0` — exit code 0 and
`rc=0` mean success.

---

## 4. Inspect the custom AI instructions in the binary

```bash
riscv64-unknown-elf-objdump -d build/demo1.elf | sed -n '/<ai_kernel>:/,/ret/p'
```

You will see raw `.word 0x…0b` encodings — these are the `custom-0` AISS
instructions (`ai.add` / `ai.mul` / `ai.relu` / `ai.matmul`) executed by the
simulator's AI unit.

---

## 5. Software-fallback path (compile the same AI ops without AI hardware)

```bash
./ai-compiler -O0 -o build/demo1_sw.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/demo1_sw.kernel.s -o build/demo1_sw.kernel.o
riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
    -ffreestanding -nostdlib -fno-builtin -Wall \
    -T runtime/riscv64.ld -nostdlib -static \
    -o build/demo1_sw.elf runtime/crt0.s build/demo1_sw.kernel.o \
    runtime/runtime.c runtime/driver.c
./rvss build/demo1_sw.elf
```

The numeric result must be identical — this proves the custom instructions are a
pure *acceleration* of the basic-instruction software path.

---

## 6. Useful simulator switches

```bash
RVSS_TRACE=1 ./rvss build/demo1.elf     # dump last 256 instructions on error
RVSS_MAX=100000 ./rvss build/demo1.elf  # cap the instruction budget
RVSS_BRK=0x80000020 ./rvss build/demo1.elf   # dump registers when PC == address
```

---

## 7. Clean up

```bash
make clean      # removes build/ plus the two host binaries
```
