# files.md — A Complete Map of Every Folder and File in This Workspace

> This document explains, **in depth**, what each directory, sub-directory, and file in
> `/Users/ryangeorge/llvm` actually does. It is written so that a new teammate or an
> external evaluator with **no prior exposure** to the project can open any file and know
> exactly why it is there.
>
> Companion reading: `explain.md` (how the project works conceptually),
> `architecture.md` (block diagrams), `README.md` (overview).

---

## 0. How to read this map

The workspace contains four **kinds** of content. The tag in brackets tells you which:

| Tag | Meaning | Tracked in git? |
|---|---|---|
| **[SOURCE]** | Hand-written project code (the compiler, simulator, runtime). | ✅ Yes |
| **[DEMO/DATA]** | Input programs and tests that drive the pipeline. | ✅ Yes |
| **[DOC]** | Markdown documentation. | ✅ Yes |
| **[BUILD OUTPUT]** | Generated binaries/objects — safe to delete with `make clean`. | ❌ Mostly ignored |
| **[VENDORED]** | Third-party LLVM toolchain source + its build tree. | ❌ Ignored |
| **[VCS]** | Git metadata. | — |

Quick top-level view:

```
/Users/ryangeorge/llvm
├── ai-compiler.c / rvss.c        [SOURCE]  the two host programs
├── runtime/                      [SOURCE]  bare-metal support code
├── demos/                        [DEMO]    3 example AI kernels (.aiir)
├── tests/                        [DEMO]    automated test script
├── docs/                         [DOC]     the custom-0 ISA spec
├── *.md                          [DOC]     the whole documentation set
├── Makefile                      [SOURCE]  build pipeline
├── build-llvm.sh / llvm-xai.patch[SOURCE]  LLVM bootstrap + our backend patch
├── ai-compiler / rvss (no ext)   [BUILD OUTPUT]  compiled host binaries
├── build/                        [BUILD OUTPUT]  demo object/ELF files
├── llvm-project/                 [VENDORED]  full LLVM/Clang/MLIR source tree
├── llvm-build/                   [VENDORED]  the compiled LLVM tools (bin/, lib/)
└── .git/                         [VCS]     repository metadata
```

The **entire "interesting" project is 3 hand-written things**: `ai-compiler.c`, `rvss.c`, and
`runtime/`. Everything under `llvm-project/` + `llvm-build/` is the (huge) standard LLVM
toolchain that we only modify in **three** files to add the AI extension.

---

## 1. Root directory (`/Users/ryangeorge/llvm`) — the source files

### 1.1 [SOURCE] `ai-compiler.c` (~331 lines) — the AI compiler
The heart of the front end. It reads an MLIR-flavoured text file (`.aiir`) and writes
RISC-V assembly (`.s`). Key parts:
- `ai_enc()` — packs a custom AI instruction into a 32-bit word (`funct7=0x0A`, `opcode=0x0B`).
- `rstrip_comments()` / `temp_of()` / `parse_dims()` — the lexer/parser helpers.
- `tensor_slot()` / `scalar_slot()` — decide where each temporary lives on the stack.
- `sw_elementwise()` / `sw_matmul()` — the `-O0` **software** lowering (plain FP loops).
- `hw_elementwise()` / `hw_matmul()` — the `-O1` **hardware** lowering (one `.word` each).
- `emit_return()` — copies the final tensor to the `OUT` pointer and emits `ret`.
- `main()` — argument parsing (`-O0`/`-O1`/`-o`), the line loop, and the code-generation driver.
Compiled by the host C compiler into the `ai-compiler` binary (see §4.1).

### 1.2 [SOURCE] `rvss.c` (~600 lines) — the chip simulator (ISS)
A single-file **instruction-set simulator** for the Rocket Chip **RV64IMAFD** ISA plus the
4 custom AI instructions. Key parts:
- `RAM_BASE/RAM_SIZE/STACK_TOP` and `load()/store()` — an 8 MB byte-array memory model at `0x80000000`.
- `ai_vadd()` / `ai_vmul()` / `ai_vrelu()` / `ai_matmul()` — the functional **AI datapath**.
- `load_elf()` — loads the program's `PT_LOAD` segments into RAM.
- `load_syms()` — finds the `tohost` mailbox symbol so the sim can service print/exit.
- `do_tohost()` — semihosting: interprets the `tohost` commands (exit / write).
- `step()` — the fetch-decode-execute loop; a big `switch` over the major opcode. `case 0x0B`
  is the AISS decoder that dispatches to the AI functions above.
- `main()` — sets up memory/registers and runs the loop until the program exits.

### 1.3 [SOURCE] `Makefile` — the build pipeline
Drives the whole demo. Notable variables/rules:
- `MARCH = -march=rv64imafd -mabi=lp64 …` — pins the ISA to Rocket Chip RV64IMAFD.
- Targets `ai-compiler` and `rvss` — build the two host tools with the **host** `cc`.
- `DEMO_RULES` — the per-demo pipeline `.aiir → .s → .o → .elf` (into `build/`).
- `test:` — runs `tests/run-tests.sh`; `dump-%` — objdump a demo; `clean:` — delete outputs.

### 1.4 [SOURCE] `build-llvm.sh` — LLVM bootstrap script (reference only)
A one-shot helper that downloads an LLVM source tarball, unpacks it, and configures/builds a
Release `clang`+`MLIR`+`RISCV` toolchain with CMake/Ninja. **Note:** the version/paths in this
script (LLVM 18.1.8, `~/llvm/build-rel`) do **not** match the toolchain actually present here
(`llvm-project/` at clang 20.x, built into `llvm-build/`), so treat it as historical/reference.
The real backend change is `llvm-xai.patch` (§1.5), applied into `llvm-project/`.

### 1.5 [SOURCE] `llvm-xai.patch` — our LLVM backend extension (3 files)
A small `git diff` patch that adds the AISS instructions to the RISC-V backend. It touches:
- `llvm/include/llvm/IR/IntrinsicsRISCV.td` — declares `llvm.riscv.ai.add/relu/mul/matmul`.
- `llvm/lib/Target/RISCV/RISCV.td` — `include "RISCVInstrInfoAI.td"`.
- `llvm/lib/Target/RISCV/RISCVInstrInfoAI.td` — **new file**: `FeatureVendorXAi` + the four
  `AI_*` instructions in `OPC_CUSTOM_0`. These changes are already applied in `llvm-project/`
  (§7.4) and compiled into `llvm-build/` (§8).

### 1.6 [BUILD OUTPUT] `ai-compiler` and `rvss` (no extension, executable)
The **compiled host binaries** produced by `make` from `ai-compiler.c` and `rvss.c`. They are
regenerated on every build and removed by `make clean`; you never edit them. (`ai-compiler`
~35 KB, `rvss` ~50 KB here.)

### 1.7 [DOC] The Markdown documentation set (root)
All hand-written docs, cross-referencing each other and the code:

| File | What it contains |
|---|---|
| `README.md` | The front door: what/why, file table, ISA provenance, pipeline diagram, quickstart. |
| `explain.md` | The beginner guide — every concept explained from scratch, plus an end-to-end trace, glossary, and evaluator Q&A. |
| `architecture.md` | Formal architecture: block diagrams, microarchitecture, memory subsystem, dataflow (Mermaid + ASCII). |
| `workflow.md` | Where the RV64IMAFD ISA comes from (Rocket/Spike provenance) and the 7 compiler stages. |
| `comparison.md` | `-O0` scalar vs `-O1` custom performance comparison (retired counts, timing method). |
| `custom.md` | Reference & commands for the **custom** AISS operations (encoding, decode, LLVM path). |
| `normal.md` | Reference & commands for the **normal** RV64IMAFD operations the simulator runs. |
| `setup.md` | One-time setup: prerequisites, how to build & run, the target-ISA note. |
| `Commands.md` | Copy-paste command catalogue for every step of the flow. |
| `TEST_RESULTS.md` | Actual captured terminal output proving each step PASSES (bit-exact numbers). |
| `files.md` | **This file** — the folder/file map. |
| `.gitignore` | Lists paths git should ignore (see §2). |

---

## 2. [SOURCE] `.gitignore` — what git ignores
Contents:
```
llvm-build/
llvm-project/.git/
llvm-project/
```
So the entire vendored LLVM source (`llvm-project/`) and its build tree (`llvm-build/`) are
**not** tracked by this project's git — they are external dependencies. `build/` artifacts are
also transient (removed by `make clean`).

---

## 3. [SOURCE] `runtime/` — bare-metal support code

This folder is everything needed to run a compiled kernel on a chip that has **no operating
system**. All four files are compiled/linked into every demo ELF.

### 3.1 `runtime/crt0.s` (~10 lines) — the entry point
Assembly `_start`. Sets the global pointer `gp` and stack pointer `sp` (to `_stack_top`), then
`call main`, and loops with `wfi` after return. This is the very first code the simulator runs.

### 3.2 `runtime/riscv64.ld` (~29 lines) — the linker script
Tells the linker the memory layout: a single 8 MB `RAM` region `ORIGIN = 0x80000000`; places
`.text` (with `.text.init`/`_start` first), `.rodata`, `.data` (defines `__global_pointer$`),
`.bss`; and reserves a 16 KiB stack at the top, exporting `_stack_top`. The `rvss` machine
model must match these addresses.

### 3.3 `runtime/runtime.c` (~51 lines) — I/O with no OS
Implements the **`tohost` mailbox** semihosting protocol (a `volatile uint64_t tohost[4]`):
- `print_str()` — write bytes to the host stdout (command `0x03`).
- `print_int()` — integer → decimal digits (no libc `printf`).
- `print_float()` — prints a float as fixed-point `d.ddd` using integer math.
- `exit_sim()` — signal exit with a code (command `0x02`).
`rvss` polls `tohost` and performs the requested action.

### 3.4 `runtime/driver.c` (~47 lines) — the `main()` shared by all demos
Declares `extern` the runtime print/exit helpers and the generated `ai_kernel(A,B,OUT)`.
`main()` prints the input arrays, calls `ai_kernel`, prints the result, and exits. It uses
fixed inputs `A = [1,-2,3,-4,5,-6,7,-8,9,…]` and `B = 2×Identity`, so expected outputs are
deterministic and testable. It is deliberately single-pass (bare-metal stack discipline).

---

## 4. [DEMO] `demos/` — example AI kernels (the input programs)

`.aiir` files: MLIR-flavoured descriptions of an AI computation. Each defines one function
`@main` taking/returning `tensor<…xf32>` and uses the ops `ai.add`/`ai.mul`/`ai.relu`/
`ai.matmul`. The `ai-compiler` consumes these.

### 4.1 `demos/demo1.aiir` — elementwise chain (`add → mul → relu`)
`%2 = ai.add(%0,%1)`, `%3 = ai.mul(%2,%0)`, `%4 = ai.relu(%3)` on `tensor<8xf32>`. Computes
`relu((A+B)*A)`. Exercises three of the four custom ops and the return path.

### 4.2 `demos/demo2.aiir` — a single 4×4 matmul
`%2 = ai.matmul(%0,%1)` on `tensor<4x4xf32>`. Exercises `ai.matmul` (the macro-op with M/K/N
in registers). With `B = 2I`, result is `2*A`.

### 4.3 `demos/demo3.aiir` — a tiny MLP layer
`%2 = ai.matmul(%0,%1)`, `%3 = ai.add(%2,%2)`, `%4 = ai.relu(%3)`. Shows **composition**:
matmul + add + relu chained on one datapath (`relu((A@B)+(A@B))`).

---

## 5. [DEMO] `tests/` — automated end-to-end checks

### 5.1 `tests/run-tests.sh` (~58 lines, executable)
The whole test suite, run via `make test`. It:
1. Runs each demo ELF through `./rvss` and asserts the header, `done`, and `exit=0`.
2. Checks the **exact numeric OUT** strings for `demo1/2/3`.
3. Rebuilds each demo with `-O0` (software path, using `-march=rv64imafd`) and asserts the
   result is **bit-identical** to the `-O1` hardware path — proving the custom instructions
   are a pure, correct speed-up. Prints `PASS`/`FAIL` and returns a failure exit code.

There are 15 `PASS` checks total (3 per demo × 3 demos + 3 software-vs-hardware matches).

---

## 6. [DOC] `docs/` — the custom ISA specification

### 6.1 `docs/riscv-aiss-spec.md` (~5.5 KB)
The formal spec of the **AISS custom-0 extension**: the R-type field layout
(`funct7=0x0A`, `opcode=0x0B`, `funct3` selecting the op), the fixed register convention, each
instruction's semantics, the `-O0`/`-O1` lowering contract, IEEE-754/NaN behaviour, and the
mapping to the LLVM `XAi` backend. This is the authoritative reference the code implements.

---

## 7. [VENDORED] `llvm-project/` — the full LLVM toolchain source

The complete upstream **LLVM monorepo** (gitignored, external). It is enormous; you only need
to know its layout and the handful of files we care about. The relevant sub-projects:

| Folder | What it is | Relevance to this project |
|---|---|---|
| `llvm/` | The core compiler infrastructure (IR, passes, targets, `llc`, `llvm-mc`, TableGen). | ⭐ **Most important** — contains the RISC-V backend we extended. |
| `clang/` | The C/C++/Objective-C front end (compiles `.c` → LLVM IR). | Used to compile demo `.c` files to IR for the LLVM path. |
| `mlir/` | MLIR: framework for IR "dialects". | Conceptual model for our `.aiir` dialect (not required to run the demo). |
| `lld/` | The LLVM linker. | Optional linking of RISC-V objects. |
| `compiler-rt/` | Runtime libs (sanitizers, builtins incl. soft-float). | Provides compiler builtins when targeting other ABIs. |
| `libcxx/`, `libcxxabi/`, `libunwind/` | C++ standard library / ABI / unwinder. | Not used by these C demos. |
| `flang/` | Fortran front end. | Not used. |
| `openmp/`, `offload/` | Parallel runtime / offloading. | Not used. |
| `polly/`, `bolt/`, `lldb/` | Loop opt, binary layout opt, debugger. | Not used (debugger potential future work). |
| `libc/`, `libclc/`, `pstl/` | C library, OpenCL C, parallel STL. | Not used. |
| `clang-tools-extra/`, `cross-project-tests/` | Extra clang tools, integration tests. | Not used. |
| `cmake/`, `runtimes/`, `third-party/`, `utils/` | Build glue, runtime orchestration, deps, helpers. | Support the build. |

### 7.4 ⭐ `llvm/` internals we touch — `llvm/lib/Target/RISCV/`
Inside `llvm/` the important areas are `include/` (headers, intrinsics), `lib/` (implementations),
`tools/` (`llc`, `clang` driver, etc.), `test/` (lit tests). The RISC-V backend lives at
`llvm/lib/Target/RISCV/`, where standard instruction files sit alongside **our** additions:

| File in `lib/Target/RISCV/` | Role |
|---|---|
| `RISCVInstrInfoAI.td` | **Our new file.** Defines `FeatureVendorXAi`, `HasVendorXAi`, and the four `AI_ADD/RELU/MUL/MATMUL` instructions (both fixed-register `AI_*_IMPLICIT` and generic `GPR` forms) in `OPC_CUSTOM_0`, plus `Pat`s from the intrinsics. |
| `RISCV.td` | Top-level target description; **modified** to `include "RISCVInstrInfoAI.td"`. |
| `llvm/include/llvm/IR/IntrinsicsRISCV.td` | **Modified** to declare `int_riscv_ai_add/relu/mul/matmul`. |
| `RISCVInstrInfoM.td` / `…A.td` / `…F.td` / `…D.td` / `…C.td` | Standard M/A/F/D/C instruction definitions for RV64IMAFD (already upstream). |
| `RISCVFeatures.td` | Feature/predicate machinery; `RISCVExtension` auto-derives the `HasVendorXAi` field & `hasVendorXAi()` getter used by our file. |
| `RISCVInstrFormats.td` | Defines `OPC_CUSTOM_0` (opcode `0x0001011` = `0x0B`) that our instructions reuse. |

> In short: within all of `llvm-project/`, only **three** files were added/changed to carry the
> AI extension — the rest is standard LLVM/RISC-V.

---

## 8. [VENDORED] `llvm-build/` — the compiled LLVM tools (CMake output)

A CMake/Ninja **build tree** for the source above (gitignored). It contains generated files
and prebuilt executables. You use it; you don't edit it.

- `bin/` — the tools we actually run:
  - `clang`/`clang++`/`clang-20` — compile C → RISC-V.
  - `llc` — the LLVM static compiler (LLVM IR → RISC-V assembly); `-mattr=+xai` enables our ops.
  - `llvm-mc` — machine-code assembler/disassembler (`--show-encoding` proves our bytes).
  - `llvm-objdump` — disassembles RISC-V objects (shows `ai.add` where GNU objdump shows `.word`).
  - `llvm-tblgen`/`clang-tblgen` — TableGen (turns `.td` into C++); `llvm-lit` — test runner.
- `lib/` — the compiled static libraries, including the RISC-V backend
  (`libLLVMRISCVCodeGen.a`, `libLLVMRISCVDesc.a`, `libLLVMRISCVInfo.a`, asm parser, disassembler).
- `lib/Target/RISCV/*.inc` — **generated** tables from our `.td`; e.g. `RISCVGenSubtargetInfo.inc`
  contains `hasVendorXAi`, and `RISCVGenAsmMatcher.inc` maps `ai.add …` → `RISCV::AI_ADD`.
- Top-level: `CMakeCache.txt` (configure options), `build.ninja` (the build graph),
  `compile_commands.json` (for editor/linter indexing), and the usual CMake scaffolding
  (`CMakeFiles/`, `cmake_install.cmake`, `CPack*.cmake`).
- `tools/`, `include/`, `unittests/`, `test/`, `examples/`, `benchmarks/`, `docs/`, `projects/`,
  `runtimes/`, `third-party/`, `utils/` — parallel output trees mirroring the source layout for
  each component; you normally don't need them.

---

## 9. [BUILD OUTPUT] `build/` — demo artifacts (created by `make`)

The intermediate and final products of the `.aiir → .s → .o → .elf` pipeline. Safe to delete
(`make clean` does). For each demo `D` in {demo1, demo2, demo3}:

| File pattern | What it is |
|---|---|
| `D.kernel.s` | Assembly the `ai-compiler -O1` produced (the custom `.word` instructions live here). |
| `D.kernel.o` | The assembled object (from `riscv64-unknown-elf-gcc -c`). |
| `D.elf` | The linked, runnable bare-metal ELF that `./rvss` executes. |
| `D_sw.kernel.s / _sw.kernel.o / _sw.elf` | The `-O0` **software-fallback** build, produced by `tests/run-tests.sh` to prove bit-exactness vs hardware. |

(Older `_O0`/`_O1` scratch files from manual experiments may also appear here; they are not
part of the standard build.)

---

## 10. [VCS] `.git/` — repository metadata

Standard Git internals (objects, refs, `HEAD`, config, hooks, index). Managed entirely by git;
never edit by hand. Its presence is why `llvm-project/` and `llvm-build/` can be ignored —
they are external, large, and re-fetchable.

---

## 11. Summary — the mental model

```
Hand-written (this is the project):
  ai-compiler.c   ─┐
  rvss.c          ─┼─► 4 custom AI ops + RV64IMAFD demo pipeline
  runtime/*       ─┘
  Makefile, tests/, demos/, docs/, *.md

Third-party (huge, only 3 files touched):
  llvm-project/   ── llvm-xai.patch applied here (RISCV XAi backend)
  llvm-build/     ── the compiled clang/llc/llvm-mc that understand "+xai"

Generated (delete any time):
  build/          ── demo .s/.o/.elf artifacts
  ai-compiler, rvss (root) ── compiled host binaries
```

**Bottom line:** open `ai-compiler.c`, `rvss.c`, and `runtime/` to understand the project;
open `demos/` + `tests/` to see it exercised; `docs/` + `*.md` explain the design; and
`llvm-project/`→`llvm-build/` show the same custom ISA reproduced inside a real, production
compiler backend.
