# files.md — An In-Depth, Plain-English Map of Every File

> This file explains, in **simple English that anyone can follow**, what each folder and file in
> `/Users/ryangeorge/llvm` is, what it does, how it works, and why it exists. You do not need any
> background in compilers, chips, or AI to read it.
>
> Related reading: `desc.md` (the code explained phase by phase), `explain.md` (deep concepts),
> `architecture.md` (diagrams), `README.md` (quick start).

---

## 0. The big picture, before any file

**What this project is.** A normal computer chip can only do a small set of basic operations. AI
programs spend most of their time doing just four things over and over: **add** two lists of
numbers, **multiply** them, apply **relu** (turn every negative number into zero), and do
**matmul** (matrix multiply, the core of neural networks). Those four operations are slow when a
chip does them one tiny step at a time.

**What we built.** We invented four *new* chip instructions — one for each of those operations —
so the chip can do a whole list in a single step. Then we:
1. wrote a small **compiler** that turns an easy-to-read recipe into those new instructions, and
2. wrote a **simulator** (a program that pretends to be the chip) to actually run them, and
3. **proved** the new instructions give exactly the same answers as doing it the ordinary way.

That "prove they match" part is the heart of the whole thing — a new instruction is only useful if
you can trust it.

**The journey every program takes** (keep this in mind; each file helps one stage):
```
  .aiir recipe  ->  ai-compiler  ->  .s assembly  ->  gcc  ->  .elf binary  ->  rvss runs it  ->  numbers
```

There are six **kinds** of things in the workspace. The label in brackets later tells you which:

| Label | What it means | Saved in git? |
|---|---|---|
| **[CODE]** | Hand-written project code (compiler, simulator, runtime, build scripts). | ✅ Yes |
| **[INPUT]** | Small example programs and tests we feed into the pipeline. | ✅ Yes |
| **[DOC]** | Markdown explanation files. | ✅ Yes |
| **[OUTPUT]** | Files the build creates automatically. Safe to delete with `make clean`. | Some tracked, some not |
| **[BORROWED]** | The huge third-party LLVM toolchain we only lightly modify. | ❌ No |
| **[GIT]** | Git's own bookkeeping. | — |

A quick look at the top level:

```
/Users/ryangeorge/llvm
├── ai-compiler.c  rvss.c        [CODE]  the two programs we wrote
├── runtime/                     [CODE]  start-up + printing helpers
├── Makefile                     [CODE]  the "build everything" recipe
├── demos/                       [INPUT] 7 example AI programs (.aiir)
├── tests/                       [INPUT] automatic checks that everything works
├── docs/                        [DOC]   the formal instruction spec
├── *.md                         [DOC]   all the explanation files
├── ai-compiler  rvss (no ext)   [OUTPUT] the compiled, runnable versions of our programs
├── build/                       [OUTPUT] files created while building the demos
├── llvm-project/                [BORROWED] full LLVM source (we touched only 3 files)
├── llvm-build/                  [BORROWED] the already-compiled LLVM tools
└── .git/                        [GIT]   repository history
```

**The one idea to hold onto:** the real project is only `ai-compiler.c`, `rvss.c`, and `runtime/`.
Everything else is glue, examples, checks, docs, generated files, or the borrowed LLVM toolchain.

---

## 1. The main code files (top level)

### 1.1 [CODE] `ai-compiler.c` — the AI compiler (our "translator")

**What it is.** A small program that reads an easy recipe (a `.aiir` file) and writes back the
low-level instructions a chip understands (a `.s` "assembly" file).

**What it does, step by step.**
1. You run it like `./ai-compiler -O1 -o out.s demo1.aiir`. It looks at that first word
   (`-O1` or `-O0`) and remembers it in a single switch called `emit_hw`. That switch decides the
   whole style of the output — see point 3.
2. It reads the `.aiir` file **line by line**, throws away the `;` comment lines, and finds the
   meaningful parts: which operation (`ai.add`, `ai.mul`, `ai.relu`, `ai.matmul`), which
   input numbers it uses, and the shape of the data (like `tensor<8xf32>` = "8 single-precision
   floats").
3. For every operation it writes out chip code in **one of two ways**:
   - **`-O1` hardware way** — it emits a **single custom instruction**, written as one 32-bit
     number like `.word 0x14730e0b`. That one number means "do this whole AI operation."
   - **`-O0` software way** — it emits an **ordinary loop** of plain instructions (load a number,
     do the arithmetic, store it, repeat). No special instructions at all.
4. At the end it copies the result into the output area and adds a "return" so control goes back.

**A concrete example of the "one number = one operation" idea.** Our four operations differ only in
a few bits. They all start and end with the same "wrapper" bytes and differ in the middle:
- add = `0x14730e0b`, mul = `0x14732e0b`, relu = `0x14031e0b`, matmul = `0x14733e0b`.
- The last byte `0x0b` marks it as one of *our* custom instructions, and a small 3-bit slot in the
  middle says which one (add/relu/mul/matmul). This is why the compiler only needs to build one
  number per step.

**Why it matters.** This file *is* the "compiler" half of the project — the thing that decides how
a human recipe becomes machine actions, and that lets us produce the same answer two different ways
so we can compare them.

### 1.2 [CODE] `rvss.c` — the chip simulator (our "pretend chip")

**What it is.** A program that behaves like the chip would. It is short for a RISC-V Simulator.
Since we don't have a physical chip with our new instructions built into it, this program stands
in and runs the compiled demos.

**What it does, step by step.**
1. **Makes a fake memory.** It reserves an 8-million-byte block of the host's own RAM and agrees
   to *call* it the chip's memory, starting at a fixed address `0x80000000`. When the program later
   says "read address …", the simulator looks inside that block.
2. **Loads the program.** It reads the `.elf` file (the compiled demo) and copies its code and
   data into that fake memory.
3. **Runs it one instruction at a time**, forever repeating three steps: *fetch* the next
   instruction, *decode* what it means, *execute* it. This is the classic heartbeat of every real
   CPU too.
4. **Knows our extra instructions.** When it meets one of our special "custom" opcodes, it does
   the matching AI operation on the fake memory — element-by-element inside a small loop. So even
   though it *looks* like one instruction to the program, under the hood it's a normal loop; the
   benefit is at the *instruction-set* level, not a real parallel hardware unit.
5. **Handles "no operating system".** Our program can't call normal print functions, so it leaves a
   small note in a known memory spot ("show this text", or "I'm finished"). The simulator keeps
   checking that spot and carries out the request. This is the semihosting "mailbox."

**Two handy extras inside it.**
- It counts how many instructions ran and prints that at the end (useful for the speed comparison).
- If you set the environment variable `RVSS_AI_TRACE=1`, it prints **each AI operation as it
  happens** — the inputs it read and the output it wrote — so you can watch the intermediate steps
  instead of only the final answer. That is exactly what makes `make demoN` show those step-by-step
  results.

**Why it matters.** Without this we could not run or see our new instructions at all. It is the
"test bench" that brings the compiled programs to life.

### 1.3 [CODE] `Makefile` — the build recipe and control panel

**What it is.** A set of instructions for the `make` tool: what to build, in what order, and with
which commands.

**What each command you type does.**
- `make` → builds the two host programs (`ai-compiler`, `rvss`) and runs the whole
  `.aiir → .s → .o → .elf` pipeline for every demo listed in `DEMOS`.
- `make demo4` → builds just that demo if needed **and runs it**, showing every intermediate AI
  step and the final result (the run target turns on the trace automatically).
- `make run-all` → runs all seven demos one after another.
- `make test` → builds everything and runs both test suites.
- `make dump-demoN` → shows the raw machine instructions of a built demo.
- `make clean` → deletes all generated files so you can start fresh.

**Why it matters.** It removes human error: the exact same sequence of tools and flags runs every
time, so results are always reproducible.

### 1.4 [CODE] `build-llvm.sh` — an LLVM setup helper (reference only)

**What it is.** A saved shell script showing how someone once downloaded and compiled the big LLVM
toolchain. **It is not used to run the demos**, and its paths are outdated. Read it only as history
— the LLVM actually present here lives in `llvm-project/` and `llvm-build/`.

### 1.5 [CODE] `llvm-xai.patch` — our tiny, official change to a real compiler

**What it is.** A "patch" is a saved list of edits you can apply to someone else's code. This one
adds our four AI instructions into LLVM's real RISC-V backend.

**Why it matters.** It proves our idea is not a toy: an industry-grade compiler can be extended the
same way, and it produces the **exact same instruction numbers** our own little compiler does.
The patch is already applied inside `llvm-project/`, and it changes just three files.

### 1.6 [OUTPUT] `ai-compiler` and `rvss` (no file extension)

**What they are.** The compiled, ready-to-run versions of `ai-compiler.c` and `rvss.c`. The build
creates them and `make clean` removes them. You never edit these — you edit the `.c` files and
rebuild.

---

## 2. [CODE] `.gitignore` — telling Git what to skip

A short list of paths Git should **not** track, so the repository stays small. It ignores the huge
borrowed LLVM folders (`llvm-project/`, `llvm-build/`) because they are external and can be
re-downloaded. (Note: the `build/` demo files are actually kept tracked here, while the transient
`build/unit/` test scratch area is left untracked.)

---

## 3. [CODE] `runtime/` — the small helpers a chip with no OS needs

Our compiled programs run on a **bare** chip — there is no Windows/Linux/macOS underneath them, no
`printf`, no keyboard, no screen. So the most basic services have to be hand-provided. These four
tiny files do that, and all four are glued into every demo program.

| File | What it does (in depth, simply) |
|---|---|
| `runtime/crt0.s` | **The starting line.** When the simulator boots the program, this is the very first code it sees. It points the stack at the top of memory and then jumps to `main`. Think of it as "power on, then start the program." |
| `runtime/riscv64.ld` | **The memory map.** It tells the linker which addresses are usable and where to place the code, the data, and the stack. It puts everything starting at address `0x80000000` — the same address the simulator treats as RAM, so the two agree. |
| `runtime/runtime.c` | **Printing and quitting without an OS.** It provides `print_str`, `print_int`, and `print_float` (which build numbers out of digits using simple math, since there is no real library) and `exit_sim`. Each of these just writes a "request" into the shared mailbox that `rvss` watches. |
| `runtime/driver.c` | **The `main()` shared by all demos.** It holds the fixed input lists `A` and `B`, prints them, calls the generated AI function `ai_kernel(A, B, OUT)`, prints the result, and quits. Because the inputs are fixed, the expected answers are always the same — perfect for testing. |

A small but important detail: `driver.c` prints only the **first 8** numbers of the result, even if
the computation produced more (for example a full 4×4 matrix has 16). The rest are still computed;
they are just not shown in the summary line.

---

## 4. [INPUT] `demos/` — the seven example programs

These are the small, human-readable recipes (`.aiir` files) we feed to the compiler. Each describes
one calculation over lists of numbers using our four operations. All of them run through the same
fixed inputs the driver provides, and all of them print their intermediate steps when run with
`make demoN`.

| File | What it demonstrates |
|---|---|
| `demos/demo1.aiir` | Elementwise chain **add → mul → relu**, i.e. `relu((A+B)·A)`. Exercises three ops on one datapath. |
| `demos/demo2.aiir` | A single **4×4 matrix multiply** — the `ai.matmul` macro-instruction. |
| `demos/demo3.aiir` | A tiny **neural-network layer**: `matmul → add → relu`, showing composition of ops. |
| `demos/demo4.aiir` | Elementwise chain **relu → add → mul** — starts with a unary relu (negatives become zero). |
| `demos/demo5.aiir` | Elementwise chain **mul → add → relu**. |
| `demos/demo6.aiir` | **Mixed** chain: a 4×4 `matmul`, then `relu`, then `add` — a matmul feeding elementwise ops. |
| `demos/demo7.aiir` | A **genuine non-square matmul** `A(2×4) @ B(4×2) → C(2×2)`, whose answers are real dot-products (not just a scaling). |

**What a `.aiir` line means, once.** `%3 = "ai.add"(%0, %1)` reads as "make a new value `%3` by
adding `%0` and `%1`." The `%0`, `%1` are the function's inputs, and `tensor<8xf32>` just says
"eight 32-bit floats."

---

## 5. [INPUT] `tests/` — automatic checks that everything is correct

These files prove the project works, so you never have to eyeball results by hand. You run them
with `make test`.

### 5.1 `tests/run-tests.sh` — the demo test suite
For every demo it checks three things: the demo ran, printed its header, and finished cleanly
(`exit=0`). Then it checks the **exact** printed numbers, and finally it rebuilds each demo the
**software** way (`-O0`) and confirms the software answer is **identical** to the hardware answer.
That last part is the key correctness proof for our custom instructions.

### 5.2 [INPUT] `tests/unit/` — one-operation-at-a-time tests
A finer suite that tests each operation alone (and in a couple of combinations) at several sizes,
comparing three sources of truth.

| File | What it does |
|---|---|
| `tests/unit/run-unit.sh` | Generates a fresh `.aiir` for every case, compiles it both ways, runs them, and checks they all match. |
| `tests/unit/unit_driver.c` | Like `driver.c`, but for a single operation; prints the operands and the result clearly. |
| `tests/unit/ref.c` | An **independent** plain-C calculation of the expected answer. This is crucial: if both of our paths somehow shared the same bug, they would still agree with each other — the independent reference is what catches that. |
| `tests/unit/show.sh` | A friendly viewer: run one case and see its operands, result, **and the generated assembly**, all labelled, with an optional step-by-step trace. |

Running `make test` exercises the demo suite **and** the unit suite together. After adding demos 4
through 7, the suite now reports **67 passing checks, 0 failures**.

---

## 6. [DOC] `docs/` — the formal rulebook for the instructions

| File | What it is |
|---|---|
| `docs/riscv-aiss-spec.md` | The official, written-down definition of our four custom instructions: exactly what each computes, how each is encoded into bits, the register rules, and the hardware-vs-software contract. The compiler and simulator are both built to obey this document — it is the single source of truth they agree on. |

---

## 7. [DOC] The Markdown explanation files (top level)

These are all hand-written documents that describe the project from different angles, so different
readers can find the level of detail they need:

| File | What it's for |
|---|---|
| `README.md` | The front door: what the project is, why it exists, and how to run it. |
| `explain.md` | The beginner guide that explains every concept from scratch. |
| `desc.md` | The code explained phase by phase (describe → translate → run → prove). |
| `viva.md` | Likely viva Q&A, each answer backed by the exact file, function, and line numbers. |
| `facts.md` | Focused implementation facts (vectorization, how normal-vs-custom is chosen, what a `.aiir` is, line-by-line assembly) with code locations. |
| `architecture.md` | Block diagrams and the overall design. |
| `workflow.md` | Where the chip type comes from and the stages from source to result. |
| `comparison.md` | How the fast (hardware) path compares to the plain (software) path. |
| `custom.md` | Commands and notes for the **custom AI** instruction path. |
| `normal.md` | Commands and notes for the **normal** instruction path. |
| `setup.md` | One-time setup: what to install and how to build and run. |
| `Commands.md` | A copy-paste list of the commands for every step. |
| `TEST_RESULTS.md` | Real captured terminal output showing the tests pass. |
| `normal_instruction_results.md` | For the normal path: inputs, output, and the generated assembly for each operation and chain. |
| `custom_ai_instruction_results.md` | For the custom AI path: the operation used, its inputs, its correct output, and the generated assembly for each case. |
| `files.md` | **This file** — the in-depth, plain-English map of everything. |

---

## 8. [BORROWED] `llvm-project/` — the full LLVM source (we touch only 3 files)

This is the complete, real LLVM compiler toolchain that was downloaded here (our Git does **not**
track it). It is enormous, but almost none of it is ours. We care about only three files that carry
our AI instructions into a genuine compiler:
- `llvm/lib/Target/RISCV/RISCVInstrInfoAI.td` — **our new file** that defines the 4 AI instructions.
- `llvm/lib/Target/RISCV/RISCV.td` — modified to include the file above.
- `llvm/include/llvm/IR/IntrinsicsRISCV.td` — modified to declare the matching built-in operations.

**Why keep a giant folder for three files?** To prove our custom instructions also work inside a
real, production-grade toolchain — the strongest evidence that the idea is sound and not a trick
that only works in our tiny compiler. Everything else in here is standard, untouched LLVM.

---

## 9. [BORROWED] `llvm-build/` — the compiled LLVM tools

This is the build output of the folder above (also not tracked). It holds ready-to-run LLVM tools
we use occasionally to double-check our work:
- `llc` — turns LLVM's internal code into RISC-V assembly (and can emit our AI instructions),
- `llvm-mc` — shows the exact instruction bytes (proving our encodings are correct),
- `llvm-objdump` — turns a binary back into readable instructions.

We **run** things from here; we never edit files here.

---

## 10. [OUTPUT] `build/` — files created while building the demos

Everything the build produces for the demos lands here, and `make clean` removes it. For each demo
you'll see three artifacts, plus their software-path twins:
- `demoN.kernel.s` — the assembly our compiler produced (the custom `.word` lives here),
- `demoN.kernel.o` — the assembled object file,
- `demoN.elf` — the final runnable program the simulator executes,
- and `demoN_sw.kernel.s` / `.o` / `_sw.elf` — the `-O0` software-path versions used to prove both
  paths agree.

There is also a `build/unit/` scratch area holding the per-operation test artifacts; it is left
untracked because it is fully regenerated by the tests. You never edit anything under `build/`.

---

## 11. [GIT] `.git/` — the repository history

Git's private store of the project's past and present — every commit, branch, and file version.
You never touch it by hand; `git` commands manage it. Its ignore rules are also what let us safely
leave the huge borrowed LLVM folders out of the repository.

---

## 12. Inside each code file, part by part

Sections 1–11 told you what each *file* is for. This section opens the files up and explains what
each *piece inside* them (every function and region) is responsible for, with the line numbers so
you can jump straight to it. All of this is still in plain English.

### 12.1 `ai-compiler.c` (the compiler, ~341 lines) — top to bottom
| Lines | Part | What this piece serves |
|---|---|---|
| 26–34 | Buffers & switches | Fix the maximum sizes; **`emit_hw` (33)** is the single on/off choice between custom (`-O1`) and plain (`-O0`) output; **`out` (34)** is the file being written. |
| 36 | `die` | Stops the program with a clear error if the input is broken. |
| 40 | `emit` | Writes one line of assembly text into the output file. |
| 47 | `ai_enc` | Packs the bit-fields (funct7, rs2, rs1, funct3, rd, opcode `0x0B`) into one 32-bit custom-instruction number. |
| 53 | `rstrip_comments` | Deletes the `;` comment from a line before reading it. |
| 58 | `temp_of` | Turns a `%N` name into a number the compiler can track. |
| 66–67 | `tensor_slot` / `scalar_slot` | Work out where on the stack each value should live. |
| 72 | `parse_dims` | Reads `tensor<8xf32>` or `tensor<2x4xf32>` and pulls out the shape numbers (and how many items). |
| 94 | `emit_src` | Emits the code that loads a value into a register before it is used. |
| 102 | `sw_elementwise` | The **`-O0` plain** path: an ordinary loop doing add/mul/relu one element at a time. |
| 131 | `hw_elementwise` | The **`-O1` custom** path: one AI instruction for add/mul/relu. |
| 142 | `sw_matmul` | The **`-O0` plain** matrix multiply: a triple loop of multiply-and-add. |
| 189 | `hw_matmul` | The **`-O1` custom** matrix multiply: one instruction, packing the M/K/N sizes into registers. |
| 202 | `emit_return` | Copies the finished result into the `OUT` area and adds the "return" back to the caller. |
| 220 | `main` | Reads the command-line arguments and sets `emit_hw` (224 for `-O1`, 225 for `-O0`), reads the `.aiir` line by line, and for each operation calls the matching `hw_*` or `sw_*` function depending on `emit_hw`. |

The key idea: everything above `main` is a small helper, and `main` is the dispatcher that picks
the hardware or software helper for each operation. That one choice is the whole `-O1` vs `-O0`
difference.

### 12.2 `rvss.c` (the simulator, ~645 lines) — top to bottom
| Lines | Part | What this piece serves |
|---|---|---|
| 36–48 | The machine's "body" | Defines the fake hardware: RAM base `0x80000000` (36), 8 MB size (37), the memory `ram` (40), 32 integer registers `x[32]` (41), 32 float registers, the program counter `pc` (43), and the `exited` stop-flag (44). The comment (48) documents the `RVSS_AI_TRACE` switch. |
| 56–57 | `trace_step` / `trace_dump` | Record and print the run trace (a small rolling buffer of what executed). |
| 67–68 | `addr_of` / `in_ram` | Turn an address into an offset into `ram`, and check an address is really inside RAM. |
| 70–82 | `load` / `store` / `store_watch` | Read from and write to the fake memory (1/2/4/8 bytes at a time). |
| 91–113 | `ai_vadd` / `ai_vmul` / `ai_vrelu` | The plain element-by-element loops that actually compute add / mul / relu. |
| 115 | `ai_matmul` | The triple loop that actually computes a matrix multiply. |
| 131 | `ai_trace_vec` | Prints a list of numbers (inputs/outputs) when the trace is on. |
| 143 | `load_elf` | Opens the `.elf` file and copies the program's code and data into fake memory. |
| 182 | `load_syms` | Reads the symbol table to find the address of the `tohost` mailbox (stored at 230). |
| 236 | `do_tohost` | Carries out the program's requests found in the mailbox — print something or stop (238–249). |
| 260–265 | `fget_d/s`, `fset_d/s` | Move double/float values in and out of their raw bit patterns. |
| 271 | `step` | **The heart.** Fetch one instruction, decode it, execute it. Our custom opcode `0x0B` is handled at **575**, choosing add/relu/mul/matmul at **584–587**; the print/exit mailbox is checked around **462–465**. |
| 624 | `main` | Sets up memory and registers, then calls `step()` again and again until the program says it's done, and prints the retired-instruction count. |

So `main` is just the repeat loop, `step` is one heartbeat, and the `ai_*` functions are what our
special instructions really do.

### 12.3 `runtime/` helpers, part by part
**`runtime/runtime.c` (~51 lines)** — the only four services a no-OS program needs:
- `print_str` (17) prints text, `print_int` (27) prints a whole number, `print_float` (38) prints a
  decimal number, `exit_sim` (46) stops the run. Each one only writes a request into the `tohost`
  mailbox; `rvss` is the one that actually does it.

**`runtime/driver.c` (~48 lines)** — the `main()` shared by every demo:
- Lines 11–16 declare the print helpers and the generated `ai_kernel`.
- Lines 18 / 21 / 27 are the fixed inputs `A[16]`, `B[16]` (2·Identity) and the result `OUT[16]`.
- `main` (29–47) prints the header and the A/B inputs (31–38), calls `ai_kernel(A, B, OUT)` (41),
  then prints the first 8 results (43–45) and `done` (46).

**`runtime/crt0.s` (~10 lines)** — the boot code: `_start` (4) sets the stack pointer, `call main`
(7), and on return spins forever `j 1b` (9).

**`runtime/riscv64.ld` (~28 lines)** — the memory layout: the `MEMORY` block (5–8) declares RAM at
`0x80000000` for 8 MB (deliberately matching `rvss`), and the `SECTIONS` block places the code
`.text` (13), the initialized data `.data` (15), the zeroed data `.bss` (19), and the stack.

### 12.4 The test scripts, part by part
**`tests/run-tests.sh`** — an `expect` helper prints PASS/FAIL by comparing real output to a
known-good string; the `for d in demo1 … demo7` loop runs each demo and checks its
exit/header/done; a block of numeric `expect` lines checks each demo's exact `OUT` values; and the
`sw_build` function rebuilds a demo the `-O0` way so its result can be compared to the `-O1` build.

**`tests/unit/`** — `run-unit.sh` writes a fresh `.aiir` for each case, compiles it `-O1` and
`-O0`, runs both, and diffs them against each other and against `ref.c`; `unit_driver.c` runs one
operation and prints its operands and result; `ref.c` is an independent plain-C answer that guards
against a shared compiler+simulator bug; and `show.sh` walks Case → inputs → `./ai-compiler` → gcc
→ `rvss` → operands + result + assembly.

> The `.aiir` files, the `docs/` and the top-level `*.md` are data and prose, not code, so there is
> nothing "internal" to break down for them — their purpose is covered in sections 4, 6 and 7.

---

## 13. The whole thing in one mental picture

```
The real project (hand-written):
  ai-compiler.c  ->  reads a .aiir recipe, writes chip instructions (two ways: custom or plain)
  rvss.c         ->  pretends to be the chip, runs the instructions, prints the numbers
  runtime/       ->  start-up, memory layout, and printing for a chip with no OS
  Makefile, demos/, tests/, docs/, *.md

Borrowed (big, only 3 files are ours):
  llvm-project/  ->  real LLVM, patched with our AI instructions
  llvm-build/    ->  the compiled LLVM tools used to double-check us

Generated (delete any time with `make clean`):
  build/, ai-compiler, rvss (the compiled programs)
```

**The bottom line, for anyone:** to understand the project, open `ai-compiler.c`, `rvss.c`, and
`runtime/`. To see it work, run `make demo1` … `make demo7` (each shows the intermediate steps).
To trust it, run `make test` (every operation is checked two independent ways). And to see the same
idea proven inside a real compiler, look at the small change in `llvm-project/`.
