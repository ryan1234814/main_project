# files.md — A Plain-English Map of Every Folder and File

> This file tells you, in simple English, what each folder and file in
> `/Users/ryangeorge/llvm` is for, and why it exists. You should be able to open any file
> after reading this and immediately know its job. No prior knowledge assumed.
>
> If you want the deeper "how it works" story, read `explain.md`. For diagrams, read
> `architecture.md`. For a quick start, read `README.md`.

---

## 0. First, the big picture

This project does one thing: it teaches a normal RISC-V computer chip a **few extra AI
instructions** (add, multiply, relu, matmul), and then proves those extra instructions give
the exact same answers as ordinary code.

To do that, the project has three hand-written pieces:
1. **A compiler** (`ai-compiler.c`) — turns a simple AI description into chip instructions.
2. **A simulator** (`rvss.c`) — a program that pretends to be the chip and runs those instructions.
3. **Runtime helpers** (`runtime/`) — small bits of code that let the program start up and
   print results without an operating system.

Everything else is either documentation, test inputs, generated output, or the borrowed LLVM
toolchain.

There are six **kinds** of things in the workspace. The label in brackets below tells you
which kind each item is:

| Label | What it means | Saved in git? |
|---|---|---|
| **[CODE]** | Hand-written project code (compiler, simulator, runtime, build scripts). | ✅ Yes |
| **[INPUT]** | Small example programs and tests we feed into the pipeline. | ✅ Yes |
| **[DOC]** | Markdown explanation files. | ✅ Yes |
| **[OUTPUT]** | Files the build creates automatically. Safe to delete with `make clean`. | ❌ Mostly not tracked |
| **[BORROWED]** | The huge third-party LLVM toolchain we only lightly modify. | ❌ No |
| **[GIT]** | Git's own bookkeeping. | — |

A quick look at the top level:

```
/Users/ryangeorge/llvm
├── ai-compiler.c  rvss.c        [CODE]  the two programs we wrote
├── runtime/                     [CODE]  start-up + printing helpers
├── Makefile                     [CODE]  the "build everything" recipe
├── demos/                       [INPUT] 3 example AI programs
├── tests/                       [INPUT] automatic checks that everything works
├── docs/                        [DOC]   the formal instruction spec
├── *.md                         [DOC]   all the explanation files
├── ai-compiler  rvss (no ext)   [OUTPUT] the compiled, runnable versions of our programs
├── build/                       [OUTPUT] files created while building the demos
├── llvm-project/                [BORROWED] full LLVM source (we touched only 3 files)
├── llvm-build/                  [BORROWED] the already-compiled LLVM tools
└── .git/                        [GIT]   repository history
```

The single most important idea: **the real project is just `ai-compiler.c`, `rvss.c`, and
`runtime/`.** The `llvm-project/` and `llvm-build/` folders are the standard LLVM toolchain —
big and borrowed — that we only change in three places to show the same idea works in a real
compiler.

---

## 1. The main code files (top level)

### 1.1 [CODE] `ai-compiler.c` — the AI compiler
This is our translator. You give it a small text file that describes an AI calculation (a
`.aiir` file), and it writes back RISC-V assembly (a `.s` file) that a chip can run.

In simple terms, inside this file:
- It reads the input line by line and understands the shapes of the number-lists.
- It can write the result **two ways**:
  - the **hardware way** (`-O1`): each AI step becomes one special instruction, and
  - the **software way** (`-O0`): each AI step becomes a plain loop of ordinary instructions.
- Both ways are meant to produce the same numbers — that sameness is our proof of correctness.

We compile this file with the normal C compiler into the runnable program called `ai-compiler`.

### 1.2 [CODE] `rvss.c` — the chip simulator
This is a program that **pretends to be the chip**. It loads our compiled demo, runs it one
instruction at a time, and shows the printed results. Because there's no real chip on the
table, this simulator is how we actually see things run.

In simple terms, inside this file:
- It reserves a block of memory to act like the chip's RAM.
- It has a main loop that repeatedly reads an instruction and does what that instruction says.
- It knows all the normal RISC-V instructions, **plus** our 4 special AI instructions.
- It handles "print to screen" and "stop the program" requests coming from the demo.

Compiling it produces the runnable program called `rvss`.

### 1.3 [CODE] `Makefile` — the build recipe
This file is the "do everything" button. Typing `make` uses it to build our two programs and
turn each demo into a runnable file. `make test` runs all the checks. `make clean` deletes the
generated files. It also pins the exact chip type we target (RV64IMAFD).

### 1.4 [CODE] `build-llvm.sh` — an LLVM setup helper (for reference)
A convenience script that shows how to download and build the LLVM toolchain. It is **not**
part of running the demos, and its paths are old, so treat it as a historical reference. The
LLVM that's actually here lives in `llvm-project/` and `llvm-build/`.

### 1.5 [CODE] `llvm-xai.patch` — our small change to LLVM
A patch is a saved set of edits. This one adds our 4 AI instructions into LLVM's RISC-V
backend, so a real compiler can also understand them. It changes only three files inside
`llvm-project/`. Those edits are already applied.

### 1.6 [OUTPUT] `ai-compiler` and `rvss` (no file extension)
These are the **compiled, ready-to-run** versions of `ai-compiler.c` and `rvss.c`. The build
creates them; `make clean` removes them. You never edit these directly — you edit the `.c`
files and rebuild.

---

## 2. [CODE] `.gitignore` — what Git should skip
A short list telling Git which folders to ignore so they don't bloat the repository. It ignores
the borrowed LLVM source and its build tree (`llvm-project/`, `llvm-build/`), because those are
external and can be re-downloaded.

---

## 3. [CODE] `runtime/` — start-up and printing helpers

Our compiled programs run on a "bare" chip with **no operating system**. So we have to provide
the most basic services ourselves. These four tiny files do that, and they get linked into
every demo.

| File | Its job, in one plain sentence |
|---|---|
| `runtime/crt0.s` | The very first code that runs: it sets up the stack and then calls `main`. |
| `runtime/riscv64.ld` | A map that tells the linker where in memory the program and stack should sit. |
| `runtime/runtime.c` | The "no OS" print helpers: how the program writes text/numbers to the screen and how it asks to stop. |
| `runtime/driver.c` | The `main()` that feeds the input numbers into our compiled AI code and prints the result. |

Because `driver.c` uses fixed input numbers, every run gives the same predictable output, which
is exactly what we want for testing.

---

## 4. [INPUT] `demos/` — the example programs (our inputs)

These are the small AI descriptions we feed into the compiler. Each one describes a calculation
over lists of numbers using our operations.

| File | What it demonstrates |
|---|---|
| `demos/demo1.aiir` | A chain of three steps: add, then multiply, then relu. |
| `demos/demo2.aiir` | A single matrix multiply (the matmul operation). |
| `demos/demo3.aiir` | A small neural-network-style layer: matmul, then add, then relu. |

---

## 5. [INPUT] `tests/` — automatic checks that everything is correct

These files run the demos and unit cases and confirm the results are right. You run them with
`make test`.

### 5.1 `tests/run-tests.sh` — the demo test suite
It runs each finished demo through the simulator and checks three things: that the demo printed
the correct numbers, that it finished cleanly, and that the **hardware** build and the
**software** build give byte-for-byte identical results. This last check is the core proof that
our special AI instructions are correct.

### 5.2 [INPUT] `tests/unit/` — one-operation-at-a-time tests
A finer-grained suite that tests each operation on its own (and in a couple of combinations),
at several sizes, always comparing hardware vs software vs an independent expected answer.

| File | Its job, in one plain sentence |
|---|---|
| `tests/unit/run-unit.sh` | Builds and runs every single-operation and chain case and checks the results match. |
| `tests/unit/unit_driver.c` | Like `driver.c`, but for one operation at a time; prints the inputs and the result. |
| `tests/unit/ref.c` | An independent, plain-C "reference" that computes the expected answer, to catch mistakes that hw/sw agreement alone would hide. |
| `tests/unit/show.sh` | A friendly one-command viewer: run a single case and print its operands, result, and generated assembly in a clean, labelled block (with optional step-by-step trace). |

Together the demo suite and the unit suite make up all the checks `make test` runs.

---

## 6. [DOC] `docs/` — the formal instruction specification

| File | What it is |
|---|---|
| `docs/riscv-aiss-spec.md` | The official written-down definition of our 4 custom instructions: what each does, how it's encoded into bits, and the rules the code follows. This is the reference the compiler and simulator are built to match. |

---

## 7. [DOC] The Markdown explanation files (top level)

These are all hand-written docs that describe the project from different angles:

| File | What it's for |
|---|---|
| `README.md` | The front door: what the project is, why it exists, and how to run it. |
| `explain.md` | The beginner guide that explains every concept from scratch. |
| `desc.md` | The code explained phase by phase (describe → translate → run → prove), in plain English. |
| `viva.md` | Likely viva Q&A, each answer backed by the exact file, function, and line numbers. |
| `facts.md` | Focused implementation facts (vectorization, how normal vs custom AI is chosen) with code locations. |
| `architecture.md` | Block diagrams and the overall design. |
| `workflow.md` | Where the chip type comes from and the stages from source to result. |
| `comparison.md` | How the fast (hardware) path compares to the plain (software) path. |
| `custom.md` | Commands and notes for the **custom AI** instruction path. |
| `normal.md` | Commands and notes for the **normal** instruction path. |
| `setup.md` | One-time setup: what to install and how to build and run. |
| `Commands.md` | A copy-paste list of the commands for every step. |
| `TEST_RESULTS.md` | Real captured terminal output showing the tests pass. |
| `normal_instruction_results.md` | For the normal path: the inputs, the output, and the generated assembly for each operation and chain. |
| `custom_ai_instruction_results.md` | For the custom AI path: the operation used, its inputs, its correct output, and the generated assembly for each case. |
| `files.md` | **This file** — the plain-English map of everything. |

---

## 8. [BORROWED] `llvm-project/` — the full LLVM source

This is the complete LLVM compiler toolchain that we downloaded (it is not tracked by our Git).
It is enormous, but we care about very little of it: the RISC-V backend, and **only three files**
we added or changed to carry our AI instructions (the work saved in `llvm-xai.patch`). Its purpose
here is to prove our custom instructions also work inside a real, production-grade compiler — not
just inside our own `ai-compiler.c`.

The few files that matter:
- `llvm/lib/Target/RISCV/RISCVInstrInfoAI.td` — **our new file** that defines the 4 AI instructions.
- `llvm/lib/Target/RISCV/RISCV.td` — modified to include the file above.
- `llvm/include/llvm/IR/IntrinsicsRISCV.td` — modified to declare the matching built-in operations.

Everything else in this folder is standard, unmodified LLVM.

---

## 9. [BORROWED] `llvm-build/` — the compiled LLVM tools

This is the build output of `llvm-project/` (also not tracked by Git). It holds the ready-to-run
LLVM tools we occasionally use to double-check our work, such as:
- `llc` — turns LLVM code into RISC-V assembly (and can emit our AI instructions),
- `llvm-mc` — shows the exact instruction bytes (proving our encodings are correct),
- `llvm-objdump` — reads a binary back into readable instructions.

We run tools from here; we never edit files here.

---

## 10. [OUTPUT] `build/` — files created while building the demos

Everything the build produces for the demos lands here, and `make clean` removes it. For each
demo you'll typically see:
- the assembly our compiler produced (`.s`),
- the assembled object file (`.o`),
- the final runnable program (`.elf`) that the simulator executes,

plus the matching software-path versions (named with `_sw`) used to prove both paths agree.
There is also a `build/unit/` area holding the per-operation test artifacts. You don't edit
anything in here.

---

## 11. [GIT] `.git/` — the repository history

Git's private storage of the project's history and current state. You never touch it by hand;
`git` commands manage it. It's also what lets us safely ignore the big borrowed LLVM folders.

---

## 12. The whole thing in one mental picture

```
The real project (hand-written):
  ai-compiler.c  →  turns an AI description into chip instructions
  rvss.c         →  a program that pretends to be the chip and runs them
  runtime/       →  start-up + printing helpers for a chip with no OS
  Makefile, demos/, tests/, docs/, *.md

Borrowed (big, only 3 files touched):
  llvm-project/  →  real LLVM, patched with our AI instructions
  llvm-build/    →  the compiled LLVM tools used to double-check us

Generated (delete any time with `make clean`):
  build/, ai-compiler, rvss (the compiled programs)
```

**Bottom line:** to understand the project, open `ai-compiler.c`, `rvss.c`, and `runtime/`.
To see it in action, look at `demos/` and run `tests/`. To understand the design, read `docs/`
and the `*.md` files. And to see the same idea proven inside a real compiler, look at the small
change in `llvm-project/`.
