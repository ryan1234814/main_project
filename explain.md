# Explain.md — A Plain-English Guide to the Whole Project

> **Who this document is for:** teammates and external evaluators who have **never seen
> this project before** and may not know compilers, CPUs, or RISC-V. Everything is
> explained from first principles — no prior knowledge assumed.
>
> **What this project is, in one line:** a *tiny custom AI processor* — we invented four
> new AI instructions, taught a compiler to emit them, and built a simulator "chip" that
> runs them, all on top of the open-source **RISC-V Rocket Chip `RV64IMAFD`** ISA.

---

## Table of Contents

0. [Background concepts (read this first if you are new)](#0-background-concepts-read-this-first-if-you-are-new)
1. [What this project does, in one picture](#1-what-this-project-does-in-one-picture)
2. [Why we built it](#2-why-we-built-it)
3. [The big idea: custom instructions on RISC-V](#3-the-big-idea-custom-instructions-on-risc-v)
4. [Which RISC-V ISA we use (Rocket Chip RV64IMAFD)](#4-which-risc-v-isa-we-use-rocket-chip-rv64imafd)
5. [The four custom AI instructions, explained](#5-the-four-custom-ai-instructions-explained)
6. [How a 32-bit instruction is encoded (bit by bit)](#6-how-a-32-bit-instruction-is-encoded-bit-by-bit)
7. [The pieces of the project (file-by-file tour)](#7-the-pieces-of-the-project-file-by-file-tour)
8. [How the compiler works, stage by stage](#8-how-the-compiler-works-stage-by-stage)
9. [How the simulator "chip" works](#9-how-the-simulator-chip-works)
10. [How the bare-metal runtime works (no OS)](#10-how-the-bare-metal-runtime-works-no-os)
11. [Memory map and stack layout](#11-memory-map-and-stack-layout)
12. [End-to-end example: trace `demo1` all the way](#12-end-to-end-example-trace-demo1-all-the-way)
13. [The three demo programs](#13-the-three-demo-programs)
14. [The two compilation modes: `-O1` hardware vs `-O0` software](#14-the-two-compilation-modes--o1-hardware-vs--o0-software)
15. [The real LLVM backend extension (`XAi`)](#15-the-real-llvm-backend-extension-xai)
16. [How to build, run, and test it yourself](#16-how-to-build-run-and-test-it-yourself)
17. [Design decisions and trade-offs](#17-design-decisions-and-trade-offs)
18. [Limitations and what is next](#18-limitations-and-what-is-next)
19. [Project status (what works today)](#19-project-status-what-works-today)
20. [Cheat sheet of commands](#20-cheat-sheet-of-commands)
21. [Anticipated questions from evaluators](#21-anticipated-questions-from-evaluators)
22. [Glossary of terms](#22-glossary-of-terms)

---

## 0. Background concepts (read this first if you are new)

Skip this section if you already know these terms.

- **CPU / processor:** the chip that runs a program by following a list of tiny steps.
- **Instruction:** one step, e.g. "add these two numbers" or "load a value from memory".
- **ISA (Instruction Set Architecture):** the *vocabulary* of instructions a CPU
  understands, plus rules for registers and memory encoding. It is the contract between
  software and hardware. Examples: x86, ARM, **RISC-V**.
- **RISC-V:** a modern, **open-source** ISA. "Open" means anyone can add their own custom
  instructions legally — that freedom is the whole point of this project.
- **Register:** a tiny, very fast storage slot *inside* the CPU. RISC-V has 32 integer
  registers named `x0`–`x31` (with friendly aliases like `t0`, `a0`, `sp`).
- **Assembly language:** human-readable text for instructions, e.g. `add t3, t1, t2`.
- **Machine code / encoding:** the actual bits the CPU reads, e.g. `0x00730e0b`.
- **Compiler:** a program that translates high-level code (like C, or our AI language) into
  assembly / machine code.
- **Assembler:** turns assembly *text* into object files (bits).
- **Linker:** glues object files together into one runnable **ELF** binary and decides
  where each piece lives in memory.
- **ELF:** the standard executable file format on Linux/RISC-V (`build/demo1.elf`).
- **Simulator / ISS (Instruction Set Simulator):** a *host* program (here written in C) that
  pretends to be the CPU: it reads an ELF and executes its instructions one by one, so we
  can "run" chip code on a normal laptop without real hardware.
- **Bare-metal:** software that runs directly on the chip with **no operating system**.
- **Float / f32 / IEEE-754:** how computers store decimal numbers. `f32` is a 32-bit
  ("single precision") float; `f64`/"d" is 64-bit ("double precision").
- **Matrix multiply (matmul):** the core math of neural networks — combine a grid of
  numbers with another grid to produce a new grid.
- **ReLU:** `max(0, x)` — the most common "activation" in neural nets (it zeroes negative
  numbers). Cheap but essential.
- **MLIR:** a Google-led framework for building compilers out of small, reusable "dialects"
  of an intermediate representation (IR). Our input file mimics MLIR syntax but we do **not**
  need real MLIR to run the demo.

---

## 1. What this project does, in one picture

The goal is a complete, self-contained loop:

```
   (1) AI source            (2) Compiler            (3) Assembly        (4) Assembler+Linker
  demos/*.aiir   ──────►   ai-compiler    ──────►  *.kernel.s  ──────►  riscv64-...-gcc  ──┐
  "relu((A+B)*A)"          (our tool)              RISC-V text          + linker script     │
                                                                                             ▼
   (6) Result on screen  ◄──────   (5) Simulator   ◄─────────────────────────────────  *.elf
   A = [...] OUT = [...]            ./rvss runs the                                       (binary)
                                    RV64IMAFD + 4 AI ops
```

In plain words:

1. You write a tiny **AI program** (`.aiir`) using high-level ops like `ai.add`, `ai.matmul`.
2. Our **compiler** (`ai-compiler`) turns it into **RISC-V assembly**.
3. The normal RISC-V **toolchain** assembles and links it into a standalone **ELF binary**.
4. Our **simulator** (`rvss`) loads that ELF and executes it — including our custom AI
   instructions — and prints the result.

This proves that new AI instructions can be designed, compiled, and executed end-to-end.

---

## 2. Why we built it

1. **AI needs fast, dedicated math.** Vector add, element-multiply, ReLU, and matrix
   multiply dominate neural-network runtimes. Real chips (TPUs, NPUs) add special hardware
   for exactly these.
2. **RISC-V lets us do it legally and openly.** Its spec explicitly reserves space for
   customer-defined instructions, so we can add ours without breaking the standard.
3. **We wanted the *whole* pipeline, not just a slide.** From a high-level description to
   bits that a (simulated) chip actually executes — with correct numerical results.
4. **No hardware purchase needed.** A C simulator stands in for the chip.

---

## 3. The big idea: custom instructions on RISC-V

Every RISC-V instruction's first 7 bits are its **major opcode** — it says "what family am
I?". The RISC-V spec reserves three families purely for customers:

| Reserved family | Major opcode | Use |
|---|---|---|
| `custom-0` | `0x0B` | **We use this** for our 4 AI ops |
| `custom-1` | `0x2B` | (unused here) |
| `custom-2/3` (for accelerators) | `0x2C/0x4C` | (unused here) |

Because standard RISC-V instructions never use opcode `0x0B`, putting our AI ops there is
**guaranteed to never collide** with normal instructions. A real Rocket Chip would simply
route `0x0B` to a custom accelerator unit — exactly what our simulator does.

**The kitchen analogy:** normal RISC-V is a kitchen with a knife (add), a stove (multiply),
etc. We added four special appliances (`ai.add`, `ai.mul`, `ai.relu`, `ai.matmul`) that do
whole tasks in one action, and a recipe book (compiler) that knows when to use an appliance
versus the basic tools.

---

## 4. Which RISC-V ISA we use (Rocket Chip RV64IMAFD)

We did **not** invent a CPU. Our base is the standard, open-source
**Rocket Chip** core's unprivileged ISA: **`RV64IMAFD`**. Decoding that name:

| Letter | Name | What it adds |
|---|---|---|
| **RV64** | 64-bit base integer (`I`) | `add`, `sub`, `lw/ld`, `sw/sd`, `beq`, `jal`, `lui`, shifts, `*W` 32-bit forms … |
| **M** | Multiply/Divide | `mul`, `div`, `rem`, … |
| **A** | Atomics | `lr`/`sc`, `amoadd`, `amoor`, … (single-hart, executed functionally) |
| **F** | Single-precision float | `flw`, `fsw`, `fadd.s`, `fmul.s`, `fmadd.s`, `fclass`, … |
| **D** | Double-precision float | the `.d` forms (`fld`, `fadd.d`, …) |

Rocket Chip and the official reference simulator **Spike** both implement this user-level
set, so anything a normal `riscv64-unknown-elf-gcc` (built with
`-march=rv64imafd -mabi=lp64`) produces runs on our simulator unchanged.

**What we intentionally leave out** to keep the demo small and readable:
- **C** (compressed 16-bit instructions). Our kernels assemble with `.option norvc`, and
  `rvss` does not decode 16-bit instructions. (A default Rocket "RV64GC" adds C; we target
  the RV64IMAFD core without it.)
- **V** (the vector extension), and privileged/CSR instructions.

You can confirm the ISA we compile for at any time:

```bash
grep MARCH Makefile
# MARCH = -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax
```

---

## 5. The four custom AI instructions, explained

All four operate on **`f32` (32-bit float) arrays that live in RAM** (not in registers).
A single instruction processes a whole tensor, driven by a fixed set of registers that the
compiler fills in *just before* emitting the instruction.

| Instruction | Math it performs | Data |
|---|---|---|
| `ai.add`   | `dst[i] = A[i] + B[i]` (element-wise) | vector of `n` floats |
| `ai.mul`   | `dst[i] = A[i] * B[i]` (element-wise) | vector of `n` floats |
| `ai.relu`  | `dst[i] = max(0, A[i])` (element-wise) | vector of `n` floats |
| `ai.matmul`| `dst = A × B` (matrix product) | `M×K` times `K×N` |

### The fixed register convention

Instead of free operands, we hard-wire meaning onto specific caller-saved registers
(`rvss.c:85` onward reads exactly these):

| Register | Alias | Meaning |
|---|---|---|
| `x5`  | `t0` | `n` — element count (for add/mul/relu) |
| `x6`  | `t1` | address of source **A** |
| `x7`  | `t2` | address of source **B** |
| `x28` | `t3` | address of **destination** |
| `x29` | `t4` | `M` (matmul rows of A) |
| `x30` | `t5` | `K` (matmul inner dimension) |
| `x31` | `t6` | `N` (matmul columns of B) |

**Why fixed registers?** One instruction can then move a whole tensor through memory without
needing a 50-instruction loop, and the OS never has to save/restore new registers (zero
context-switch cost). The trade-off is less flexibility — fine for a demo.

So a typical AI op in assembly looks like:

```asm
li    t0, 8            # n = 8 floats
mv    t1, a0           # t1 = address of A
mv    t2, a1           # t2 = address of B
addi  t3, sp, -16      # t3 = address of destination slot on the stack
.word 0x14730e0b       # <-- the custom ai.add instruction (raw bits)
```

---

## 6. How a 32-bit instruction is encoded (bit by bit)

Every one of our instructions is a normal 32-bit RISC-V **R-type** word. The fields:

```
 31      25 24    20 19    15 14    12 11     7 6      0
+----------+--------+--------+--------+---------+--------+
|  funct7  |  rs2   |  rs1   | funct3 |   rd    | opcode |
+----------+--------+--------+--------+---------+--------+
   0x0A     (fixed)  (fixed)   selects  (fixed)   0x0B
   "AISS"            reg        which    reg     "custom-0"
                    (t1=6)      AI op    (t3=28)
                                 (0-3)
```

- `opcode = 0x0B` → "this is a custom-0 instruction".
- `funct7 = 0x0A` → "this is an AISS instruction" (distinguishes us from other custom-0 users).
- `funct3` → which of the four ops:
  - `0 = ai.add`, `1 = ai.relu`, `2 = ai.mul`, `3 = ai.matmul`.
- `rd/rs1/rs2` carry our fixed register numbers (`t3=28`, `t1=6`, `t2=7`).

The function that builds these words is `ai_enc()` at `ai-compiler.c:47`:

```c
(funct7<<25) | (rs2<<20) | (rs1<<15) | (funct3<<12) | (rd<<7) | 0x0B
```

Plugging in `funct7=0x0A, rd=28(t3), rs1=6(t1), rs2=7(t2)`:

| Instruction | funct3 | Encoded word |
|---|---|---|
| `ai.add`    | 0 | `0x14730e0b` |
| `ai.relu`   | 1 | `0x14031e0b` |
| `ai.mul`    | 2 | `0x14732e0b` |
| `ai.matmul` | 3 | `0x14733e0b` |

These exact four words are the entire custom ISA. GNU `objdump` does not know them and
prints `.word 0x14730e0b` (or `.insn`), which is expected — but our LLVM build (`llvm-mc`)
and `rvss` both understand them.

---

## 7. The pieces of the project (file-by-file tour)

```
.
├── ai-compiler.c        # (~331 lines) The compiler: .aiir -> RISC-V .s
├── rvss.c               # (~600 lines) The chip simulator: runs RV64IMAFD + AISS
├── runtime/
│   ├── crt0.s           # (~10 lines)  _start: set stack/global pointers, call main
│   ├── riscv64.ld       # linker script: lay everything out in RAM @ 0x80000000
│   ├── runtime.c        # (~51 lines)  print_str/print_int/print_float/exit_sim via tohost
│   └── driver.c         # (~47 lines)  main(): builds A/B, calls ai_kernel, prints OUT
├── demos/
│   ├── demo1.aiir       # add -> mul -> relu
│   ├── demo2.aiir       # 4x4 matmul
│   └── demo3.aiir       # matmul + add + relu (a tiny MLP layer)
├── Makefile             # the build pipeline (make / make test / make clean)
├── tests/run-tests.sh   # 15 automated end-to-end checks
├── docs/riscv-aiss-spec.md  # the custom-0 ISA specification we invented
├── llvm-project/…/RISCV/RISCVInstrInfoAI.td  # the LLVM backend version of XAi
└── *.md                 # documentation (this file, README, architecture, …)
```

Two host programs do the heavy lifting:

- **`ai-compiler`** (from `ai-compiler.c`) — reads a `.aiir` file and writes RISC-V `.s`.
- **`rvss`** (from `rvss.c`) — the "chip": loads an ELF and executes it.

The **runtime** directory is what lets the program run with no operating system, and the
**demos** are the test applications.

---

## 8. How the compiler works, stage by stage

`ai-compiler.c` is a classic small compiler. A line of AI code passes through these stages:

```
%2 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
```

1. **Preprocess / tokenize.** `rstrip_comments()` (`ai-compiler.c:53`) strips `;` comments;
   `temp_of()` (`:58`) extracts `%0`-style names; `parse_dims()` (`:70`) reads
   `tensor<8xf32>` shape numbers.
2. **Parse (grammar).** `main()` (`:210`) recognises `ai.func` / `ai.entry` / `"ai.*"` ops /
   `ai.return`, and `die()`s on malformed input (`:272`).
3. **Validate (semantics).** Range checks: temp id `< 64` (`:63`), element counts within the
   per-mode limits (`:93`, `:122`), a required `ai.return` (`:324`).
4. **Assign storage (the "IR").** There are no real tensor registers; the **stack is the
   notebook**. `%0`/`%1` are the incoming pointers `a0`/`a1`; every produced tensor `%t`
   lives in a 64-byte slot at `sp - tensor_slot(t)` where `tensor_slot(t)=16+64*(t-2)`
   (`:66`); scalar temporaries live at `sp - scalar_slot(t)`, `scalar_slot(t)=1024+4*t`
   (`:67`).
5. **Choose lowering (the "optimization" decision).** The `-O1` flag sets `emit_hw`
   (`:33`, `:214`). `-O1` → `hw_elementwise()`/`hw_matmul()` (one custom `.word`, `:121`
   /`:179`). `-O0` → `sw_elementwise()`/`sw_matmul()` (plain scalar loops, `:92` /`:132`).
6. **Emit assembly.** `emit()` (`:40`) writes text; `emit_src()` (`:84`) sets up pointers;
   `ai_enc()` (`:47`) builds the custom word; `emit_return()` (`:192`) copies the final
   tensor to the `OUT` pointer and emits `ret`.
7. **Assemble + link (outside our compiler, via `make`).** `riscv64-unknown-elf-gcc` turns
   `.s` into `.o` and links it with `crt0.s`, `runtime.c`, `driver.c` into an ELF.

The emitted header always includes `.option norvc` (no compressed instructions) and exports
one function, `ai_kernel`.

---

## 9. How the simulator "chip" works

`rvss.c` is a single-Hart (single core) interpreter:

1. **Load the ELF.** `load_elf()` (`:119`) copies each `PT_LOAD` segment into a `malloc`'d
   8 MB byte array representing RAM, based at `0x80000000`.
2. **Find the mailbox.** `load_syms()` (`:162`) parses the symbol table to find the address
   of `tohost` (the print/exit channel, see §10).
3. **Set up registers.** `sp = _stack_top`, `gp = RAM_BASE`, everything else zero.
4. **Fetch-decode-execute loop.** `step()` (`:247`) reads 4 bytes at `pc`, splits the bit
   fields (`op`, `rd`, `funct3`, `rs1`, `rs2`, `funct7`, immediates), and a big `switch`
   on `op` runs the matching behaviour:
   - normal RV64I/M/A/F/D groups (`:299` onward),
   - **`case 0x0B` at `rvss.c:557`** — the AISS decoder: it checks `funct7 == 0x0A`, then
     dispatches to `ai_vadd` / `ai_vrelu` / `ai_vmul` / `ai_matmul` (`:564`+) based on
     `funct3`.
5. **The AI unit.** Functions `ai_vadd()` (`:85`), `ai_vmul()` (`:93`), `ai_vrelu()` (`:101`),
   `ai_matmul()` (`:109`) read float bits from RAM with `memcpy` (so IEEE-754 is exact), do
   the math in host `float`, and write results back to RAM.
6. **Semihosting check** after every step (`do_tohost()`).

Floating-point is faithful: FP registers store raw IEEE-754 bits and `f32` values are
**NaN-boxed** (upper 32 bits set) exactly like the RV64 F/D ABI. Debug aids: the last 256
instructions are kept in a ring buffer and dumped on a fault, and env vars `RVSS_TRACE`,
`RVSS_MAX`, `RVSS_BRK`, `RVSS_WATCH` control tracing/limits/breakpoints.

---

## 10. How the bare-metal runtime works (no OS)

A bare chip has no `printf`, no `exit()`, no syscalls. We fake I/O with a agreed-upon RAM
address called **`tohost`** (a "mailbox"). The CPU writes commands there; the simulator
polls it and acts. This is the standard RISC-V **HTIF/semihosting** idea.

Protocol (defined in `runtime/runtime.c`, handled in `rvss.c:215`):

| `tohost[0]` value | Meaning | Extra fields |
|---|---|---|
| `1` | exit with code 0 | — |
| `2` | exit with a code | `tohost[1]` = exit code |
| `3` | write bytes to "stdout" | `tohost[1]` = buffer address, `tohost[2]` = length |

The runtime offers `print_str`, `print_int` (integer→digits), `print_float` (prints
fixed-point `d.ddd` without a C library), and `exit_sim`. `crt0.s` is the entry point: it
sets `gp` and `sp`, then `call main`. `driver.c`'s `main()` builds the input arrays, calls
the compiled kernel `ai_kernel(A, B, OUT)`, prints the result, and exits.

---

## 11. Memory map and stack layout

**The simulated 8 MB RAM (`runtime/riscv64.ld`):**

```
0x807FFFF0  <- _stack_top  (sp starts here; stack grows DOWN)
              … stack (kernel temporaries) …
              .bss   (tohost/fromhost mailboxes, 64-byte aligned)
              .data  (initialised globals: A[], B[])
              .rodata
0x80000000  <- .text (crt0 `_start`, then main, ai_kernel, runtime)  == RAM_BASE
```

**Inside `ai_kernel`, the compiler's stack "notebook":**

```
sp        -> (top of our frame)
sp - 16   -> tensor %2 slot  (64 bytes = up to 16 f32)
sp - 80   -> tensor %3 slot
sp - 144  -> tensor %4 slot
  …
sp - 1024 -> scalar temp %0 (4 bytes)
sp - 1028 -> scalar temp %1
```

Inputs `%0`/`%1` are the pointers already sitting in `a0`/`a1` on entry. The result tensor
is copied to `OUT` (argument `a2`) before `ret`.

---

## 12. End-to-end example: trace `demo1` all the way

`demos/demo1.aiir`:

```
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %3 = "ai.mul"(%2, %0)  : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %4 = "ai.relu"(%3)     : (tensor<8xf32>) -> tensor<8xf32>
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
```

It computes `relu( (A + B) * A )` on 8 floats.

**What the compiler emits (`-O1`, `build/demo1.kernel.s`):**

```asm
ai_kernel:
        li    t0, 8                 # n
        mv    t1, a0                # A
        mv    t2, a1                # B
        addi  t3, sp, -16           # dst = %2
        .word 0x14730e0b            # ai.add  -> %2 = A + B

        li    t0, 8
        addi  t1, sp, -16           # %2
        mv    t2, a0                # A
        addi  t3, sp, -80           # dst = %3
        .word 0x14732e0b            # ai.mul  -> %3 = %2 * A

        li    t0, 8
        addi  t1, sp, -80           # %3
        addi  t3, sp, -144          # dst = %4
        .word 0x14031e0b            # ai.relu -> %4 = max(0,%3)

        # ai.return: copy the result tensor %4 to OUT (a2) with a flw/fsw loop, then ret
```

**Then `make`** assembles this to `demo1.kernel.o` and links it with `crt0.s`, `runtime.c`,
`driver.c` into `build/demo1.elf`.

**Then `rvss`** runs it: `driver.c`'s `main()` calls `ai_kernel(A, B, OUT)`. Each `.word`
reaches `rvss.c:557`, which sees `opcode 0x0B` + `funct7 0x0A` and calls the matching AI
function, writing results into the stack slots. Finally `main()` prints `OUT` through the
`tohost` mailbox and exits.

**Output (`./rvss build/demo1.elf`):**

```
== AISS demo ==
A (operand) = [1.0 -2.0 3.0 -4.0 5.0 -6.0 7.0 -8.0 ]
B (operand) = [2.0 0.0 0.0 0.0 0.0 2.0 0.0 0.0 ]
Running ai_kernel(A, B, OUT) ...
OUT (result) = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]
done
```

Only the final `OUT` is printed above. But **three** operations ran to get there, each
transforming the operands and feeding the next. To see every intermediate result, run
the simulator with `RVSS_AI_TRACE=1` (or `bash tests/unit/show.sh demo1 hw trace`). It
prints, for each custom instruction, the exact inputs it received and the vector it
wrote — in execution order:

```
[ai-trace] step 1: ai.add  (.word 0x14730e0b)   length: n=8
    srcA: [1 -2 3 -4 5 -6 7 -8 ]      <- A
    srcB: [2 0 0 0 0 2 0 0 ]          <- B
    dst:  [3 -2 3 -4 5 -4 7 -8 ]      <- %2 = A + B

[ai-trace] step 2: ai.mul  (.word 0x14732e0b)   length: n=8
    srcA: [3 -2 3 -4 5 -4 7 -8 ]      <- %2 (from step 1)
    srcB: [1 -2 3 -4 5 -6 7 -8 ]      <- A
    dst:  [3 4 9 16 25 24 49 64 ]      <- %3 = %2 * A

[ai-trace] step 3: ai.relu (.word 0x14031e0b)   length: n=8
    srcA: [3 4 9 16 25 24 49 64 ]     <- %3 (from step 2)
    dst:  [3 4 9 16 25 24 49 64 ]      <- %4 = max(0, %3)  (no negatives, so unchanged)
```

So the full chain for element 0 is `1 + 2 = 3`, then `3 * 1 = 3`, then `relu(3) = 3`;
for element 5 it is `-6 + 2 = -4`, then `-4 * -6 = 24`, then `relu(24) = 24`. When an
earlier step produces a negative and a later `relu` clamps it to `0`, the trace shows
that sign change too (see `demo3` / the `add->relu->mul` chain in `TEST_RESULTS.md`).

---

## 13. The three demo programs

Inputs come from `runtime/driver.c`: `A = [1,-2,3,-4,5,-6,7,-8,…]` and `B = 2×Identity`.

| Demo | Ops used | Computes | Printed OUT (first 8) |
|---|---|---|---|
| `demo1` | `ai.add`, `ai.mul`, `ai.relu` | `relu((A+B)*A)` | `3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0` |
| `demo2` | `ai.matmul` | `A × 2I = 2A` | `2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0` |
| `demo3` | `ai.matmul`, `ai.add`, `ai.relu` | `relu((A@B)+(A@B))` | `4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0` |

Together they exercise every custom op and a realistic chained AI pattern (an MLP layer).

---

## 14. The two compilation modes: `-O1` hardware vs `-O0` software

This is a **key correctness argument** for the project.

- **`-O1` (hardware path):** each AI op becomes **one** custom `.word` instruction — fast,
  few instructions.
- **`-O0` (software fallback):** each AI op is expanded into an ordinary RV64IMAFD scalar
  loop (`flw`/`fadd.s`/`fsw`, etc.) using **only standard instructions**.

The tests compile **both** and assert they produce **bit-identical** outputs. That proves
the custom instructions are *pure acceleration*: turning the special hardware on changes
speed, never the numerical answer. (`tests/run-tests.sh` → "sw demoN matches hardware".)

---

## 15. The real LLVM backend extension (`XAi`)

Beyond the standalone compiler, the same `custom-0` ISA is implemented as a **real LLVM
RISC-V backend extension**, proving it would slot into a production toolchain:

- **Instruction definitions:** `llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td`
  declares `FeatureVendorXAi` and the four `AI_*` instructions in `OPC_CUSTOM_0`.
- **Intrinsics:** `llvm/IR/IntrinsicsRISCV.td` defines `llvm.riscv.ai.add/relu/mul/matmul`,
  mapped to the instructions via `Pat`.
- **How it turns on:** the RISC-V subtarget auto-generates a `hasVendorXAi()` getter from
  the feature, enabled with `-mattr=+xai` (or `-march=rv64gc_xai`).

Verified with the already-built LLVM in `llvm-build/bin/`:

```bash
# Assembler knows the mnemonics and emits our exact words:
./llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding \
  <<< $'\t.text\n\tai.add'         # -> [0x0b,0x0e,0x73,0x14] = 0x14730e0b

# Compiler lowers the intrinsic to the instruction:
./llvm-build/bin/llc -mtriple=riscv64 -mattr=+xai -filetype=asm /tmp/ai.ll
```

The LLVM path and the standalone `ai-compiler` produce **byte-identical** encodings, and
`rvss` runs either one.

> Note: this document does **not** require rebuilding LLVM — `llvm-build/` already contains
> the compiled `XAi` extension, which we validated by running `llvm-mc`/`llc` directly.

---

## 16. How to build, run, and test it yourself

From the project root (`/Users/ryangeorge/llvm`):

```bash
# Prerequisites: a host C compiler (cc), make, and the RISC-V cross toolchain.
riscv64-unknown-elf-gcc --version     # if missing: brew install riscv-gnu-toolchain

# 1) Build the compiler, the simulator, and all three demo ELFs:
make clean && make

# 2) Run the automated test suite (expect 15 PASS, 0 FAIL):
make test

# 3) Run a demo on the simulated chip:
./rvss build/demo1.elf
./rvss build/demo2.elf
./rvss build/demo3.elf
```

To see the raw custom instructions in the generated assembly:

```bash
grep -n "\.word" build/demo1.kernel.s
```

To compile a single demo by hand and inspect every stage:

```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax \
    -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding \
    -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static -o build/demo1.elf \
    runtime/crt0.s build/demo1.kernel.o runtime/runtime.c runtime/driver.c
./rvss build/demo1.elf
```

---

## 17. Design decisions and trade-offs

1. **Standard custom space, not a stolen opcode.** Using `custom-0 (0x0B)` keeps us
   compatible with real RISC-V tooling and cores; nothing standard uses that opcode.
2. **Fixed registers for tensor ops.** One instruction moves a whole tensor; the cost is
   flexibility. Good for a clear demo.
3. **Bit-exact software fallback.** Guarantees the custom path is a pure speed-up and gives
   a strong, testable correctness property (see §14).
4. **Keep the ISA slice small.** Implement RV64IMAFD (with A functional); skip C/V/privileged
   so `rvss.c` stays a readable ~600 lines.
5. **Stack as the register file for tensors.** Simple, predictable slot addressing
   (`tensor_slot`/`scalar_slot`) instead of a real register allocator.
6. **Demo size limits.** Software path ≤ 16 elements, hardware path ≤ 32, matmul ≤ 4×4 —
   chosen so simulation stays fast. These are demo ceilings, not ISA limits.
7. **IEEE-754 correctness.** `memcpy` of raw float bits + RV64 NaN-boxing keep results exact;
   `relu` maps `-0.0 → 0.0`.
8. **Semihosting for I/O.** The `tohost` mailbox is the smallest thing that lets bare-metal
   C print and exit on a simulated chip.
9. **Performance proxy.** "retired instructions" from `rvss` stands in for cycles (CPI = 1)
   on a hypothetical chip; host wall-clock time is *not* the target metric.
10. **Deterministic inputs.** `driver.c` fixes `A` and `B` so expected outputs are known and
    unit-testable.

---

## 18. Limitations and what is next

**Honest limitations of the current demo:**
- No compressed (C), vector (V), or privileged instructions; atomics are functional on a
  single hart (no real concurrency/locking).
- Small tensor limits and a naive stack-based allocator (no real register allocation).
- `print_float` only prints fixed-point `d.ddd`.
- The AI unit models *what* is computed, not timing/power of real silicon.

**Roadmap toward a full system:**

| Phase | What to build | Why |
|---|---|---|
| More ops | `ai.conv2d`, `ai.softmax`, `ai.gelu`, `ai.layer_norm` | Real networks need them |
| Bigger shapes | >4×4 matmul, dynamic `tensor<?x?xf32>`, tiling, DMA | Leave demo limits behind |
| Real MLIR/LLVM front end | Feed `mlir-opt` / a PyTorch/TensorFlow export into our passes | So real models use it |
| Better codegen | Register allocation, loop fusion, int8 quantization | Reduce memory traffic |
| Real hardware | Synthesize the AISS unit on an FPGA next to a Rocket/BOOM core; boot via HTIF | Prove silicon speed, not just `retired` |
| Toolchain polish | Teach GNU `binutils`/`gdb` the mnemonics (today they show `.word`) | Developer ergonomics |

The "100%" picture: `python model.py → MLIR → llc (XAi) → FPGA → result`, with no simulator.

---

## 19. Project status (what works today)

- [x] Four custom AI instructions designed in `custom-0` (`docs/riscv-aiss-spec.md`).
- [x] A standalone compiler (`ai-compiler`) with dual lowering (`-O1` hardware / `-O0` software).
- [x] A simulator (`rvss`) executing the full **Rocket Chip RV64IMAFD** slice + the AISS unit.
- [x] A bare-metal runtime (`crt0.s`, `runtime.c`, `driver.c`, `riscv64.ld`) using `tohost`.
- [x] Three demos plus **15 automated checks** that all PASS, including bit-exact
      `-O0` vs `-O1` equivalence.
- [x] A **real LLVM `XAi` backend** (`RISCVInstrInfoAI.td` + intrinsics) emitting
      byte-identical encodings via `llc`/`llvm-mc`/`clang -mattr=+xai`.

In short: the entire loop — *AI source → compiler → RISC-V assembly → ELF → simulated chip
→ correct numeric output* — works today, both through a hand-written compiler and through a
production LLVM backend.

---

## 20. Cheat sheet of commands

```bash
make clean && make            # build everything
make test                     # 15 checks
make demo1                     # build + run demo1 on rvss
./rvss build/demo2.elf         # run a demo directly
./ai-compiler -O0 -o /tmp/d1_O0.s demos/demo1.aiir && cat /tmp/d1_O0.s
./ai-compiler -O1 -o /tmp/d1_O1.s demos/demo1.aiir && grep "\.word" /tmp/d1_O1.s

# Simulator debug switches:
RVSS_TRACE=1  ./rvss build/demo1.elf   # dump last 256 instructions
RVSS_MAX=100000 ./rvss build/demo1.elf # cap executed instructions
RVSS_BRK=0x80000020 ./rvss build/demo1.elf   # dump registers at an address

# Clean up:
make clean
```

---

## 21. Anticipated questions from evaluators

**Q: Is this a real chip?**
A: Not physical silicon. `rvss` is a functional **instruction-set simulator** — the
accepted, standard way to validate an ISA before building hardware. The ISA and encodings
are real and toolchain-compatible.

**Q: Why RISC-V and not ARM/x86?**
A: RISC-V is open and explicitly reserves custom opcode space (`custom-0`), so we can add
instructions legally. ARM/x86 are closed and do not permit this.

**Q: Doesn't using `.word` (raw bits) mean the assembler "supports" it?**
A: The GNU assembler just packs the bits — it does not need to understand them, which is
precisely why the instruction is safe to run (it can only be `custom-0`). Our LLVM build
*does* understand the mnemonics (see §15).

**Q: How do you know the custom result is correct?**
A: The `-O0` software fallback uses only standard, already-verified RISC-V FP instructions.
The tests require it to be **bit-identical** to the `-O1` custom path for all demos.

**Q: Which ISA, exactly?**
A: The unprivileged **Rocket Chip `RV64IMAFD`** base (I+M+A+F+D). We target the RV64IMAFD
core without the optional compressed (C) extension.

**Q: What is the value of the fixed-register convention?**
A: A single instruction can drive a whole tensor through memory, and no new architectural
registers means zero context-switching overhead. The trade-off (less flexibility) is fine
for this scope.

---

## 22. Glossary of terms

| Term | Meaning |
|---|---|
| **ISA** | Instruction Set Architecture — the CPU's instruction "vocabulary". |
| **RV64IMAFD** | 64-bit base + Integer **I**, Multiply **M**, Atomics **A**, Float **F**, Double **D**. |
| **Rocket Chip** | A well-known open-source RISC-V CPU whose base ISA is RV64IMAFD. |
| **custom-0 (0x0B)** | RISC-V opcode reserved for customer extensions; where our AI ops live. |
| **funct7 / funct3** | Bit fields inside an instruction that select a specific operation. |
| **`.aiir`** | This project's MLIR-flavoured AI source file format. |
| **`ai-compiler`** | The compiler that turns `.aiir` into RISC-V assembly. |
| **`rvss`** | The RISC-V + AISS instruction-set simulator (the "chip"). |
| **`XAi`** | The LLVM backend extension that implements the same custom instructions. |
| **ELF** | The standard executable file format. |
| **`tohost`** | A RAM "mailbox" used for semihosted print/exit on bare metal. |
| **f32 / IEEE-754** | 32-bit floating-point numbers and the standard that defines them. |
| **ReLU** | Rectified Linear Unit: `max(0, x)`. |
| **matmul** | Matrix multiplication — core neural-network operation. |
| **NaN-boxing** | The RV64 rule for storing a 32-bit float inside a 64-bit FP register. |
| **Semihosting / HTIF** | How bare-metal code talks to the host (print, exit) without an OS. |
| **retired** | Number of instructions the simulator executed; used as a cycle proxy. |
```
