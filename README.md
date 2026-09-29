# AISS — a tiny RISC-V AI-instruction compiler + ISA simulator demo

This project demonstrates, end to end, how a **custom set of AI instructions** can be
added to the **Rocket Chip RV64IMAFD** RISC-V ISA, how a **compiler lowers a small
MLIR-style AI dialect** onto those instructions, and how a **RISC-V chip simulator**
executes the result — including the custom instructions on a simulated AI datapath.
The four AI instructions live in the RISC-V **`custom-0`** opcode space, so they never
clash with Rocket's standard RV64IMAFD instructions and run on the same core.

Everything is intentionally **minimal**: two small C programs, a bare-metal runtime,
eight demo kernels, and a Makefile. No LLVM/MLIR install is required to run the demo
(the input language is an MLIR-*flavoured* text IR, parsed by a ~600-line compiler).

> **New (2026-09-17):** The same AISS custom-0 extension (`XAi`, `custom-0 0x0B f7 0x0A`) is now also implemented as a **real LLVM RISC-V backend extension** (`llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td`, `IntrinsicsRISCV.td: int_riscv_ai_*`, `llvm-build/bin/clang|llc|llvm-mc --mattr=+xai / -march=rv64gc_xai`). Both the standalone `ai-compiler` and the LLVM `llc` emit byte-identical `0x14730e0b` encodings, verified via `llvm-mc --show-encoding` and `rvss` (see `TEST_RESULTS.md` §4).

---

## 1. What is in this repo

| File | What it is |
|------|------------|
| `ai-compiler.c` → `ai-compiler` | Compiler: MLIR-style `.aiir` → RISC-V RV64IMAFD assembly. `-O1` emits the **custom AI instructions** as raw `.word` encodings; default (`-O0`) lowers the same AI ops to plain scalar RV64IMAFD loops. |
| `llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td` + `llvm/IR/IntrinsicsRISCV.td` → `llvm-build/bin/clang\|llc\|llvm-mc` | **Real LLVM XAi extension** (`-march=rv64gc_xai` / `-mattr=+xai`): fixed-register `AI_*_IMPLICIT` (`Defs=[X28] Uses=[X5,X6,X7]`) via `llvm.riscv.ai.*` intrinsics **and** generic `ai.add t3,t1,t2` forms. Emits byte-identical `0x14730e0b`/`0x14031e0b`/… as the standalone compiler (verified `llc` → `llvm-mc --show-encoding` → `rvss`). |
| `rvss.c` → `rvss` | RISC-V instruction-set simulator (ISS): decodes and executes the **Rocket Chip RV64IMAFD** unprivileged ISA **plus the 4 custom AI instructions** on a simulated AI unit. |
| `runtime/crt0.s` | Bare-metal startup (`_start`: set `gp`/`sp`, call `main`). |
| `runtime/riscv64.ld` | Linker script: everything placed in RAM at `0x80000000`, `_stack_top` on top. |
| `runtime/runtime.c` | Semihosting via the `tohost` mailbox: `print_str`, `print_int`, `print_float`, `exit_sim`. |
| `runtime/driver.c` | The bare-metal `main()` shared by all demos: holds the *fallback* input arrays, applies the demo's own `; @operands:` table if there is one, calls the compiled `ai_kernel(A, B, OUT)`, prints the results. |
| `demos/demo1.aiir` | Elementwise chain `relu((A+B)*A)` on 8×f32 → exercises `ai.add`, `ai.mul`, `ai.relu`. |
| `demos/demo2.aiir` | 4×4×f32 matrix multiply → exercises `ai.matmul`. |
| `demos/demo3.aiir` | Tiny MLP layer `relu((W·x) + (W·x))` → exercises `ai.matmul` + `ai.add` + `ai.relu` chained on one datapath. |
| `demos/demo4..8.aiir` | More shapes and op orders: reversed chains, a non-square `2×4 @ 4×2` matmul, and a demo that overrides only `A` (so `B` stays the driver default). Each one names its own operands in its header. |
| `Makefile` | Builds the tools, compiles every demo `.aiir` → `.s` → `.o` → ELF, and runs them on `rvss`. |

---

## 2. Which RISC-V ISA is this? (Rocket Chip provenance)

This project targets the **Rocket Chip** open-source RISC-V core, whose unprivileged
base ISA is **RV64IMAFD** — that is RV64I (base integer) + **M** (multiply) + **A**
(atomics) + **F** (single-precision float) + **D** (double-precision float). Every
binary here is built for exactly that ISA (`-march=rv64imafd -mabi=lp64`), and the `rvss`
simulator executes the same instruction set, so anything `riscv64-unknown-elf-gcc`
or the LLVM RISC-V backend emits for Rocket runs unmodified.

The simulator implements the parts of RV64IMAFD that the demos actually use:

* **RV64I** — all base integer instructions used by `riscv64-unknown-elf-gcc -O2`
  bare-metal output: loads/stores, ALU ops, `lui`/`auipc`, shifts, branches, `jal`/`jalr`,
  64-bit and 32-bit (`*W`) forms.
* **M** — `mul/mulh/mulhu/mulhsu/div/divu/rem/remu` (RV64M).
* **A** — atomics are part of the ISA string (Rocket RV64**A**FD); the ISS executes
  `LR/SC` and all `AMO*.{W,D}` functionally on the single hart (`rvss.c:407`).
* **F/D** — FP loads/stores, `fadd/fsub/fmul/fdiv/fsqrt`, FMA, `fmin/fmax`,
  sign-injection, comparisons, conversions, `fmv.x.w/fmv.w.x`, `fclass` — with the
  RV64 **NaN-boxing** rule for 32-bit floats.
* **C (compressed)** is intentionally not used by the demo kernels (`.option norvc`),
  matching a bare Rocket core without the C bitstream option.

This is exactly the user-level ISA implemented by **UC Berkeley Rocket** and the official
reference simulator **Spike (riscv-isa-sim)**, so ordinary `riscv64-unknown-elf-gcc`
output (built for `-march=rv64imafd -mabi=lp64 -mcmodel=medany`) runs unmodified.

### The custom AI instructions use the *custom-0* opcode space

The RISC-V spec reserves the major opcodes **`custom-0` (0x0B)** and `custom-1` (0x2B)
for per-implementation custom extensions. This is the standard mechanism open-source
cores (Rocket, BOOM, Spike) use to attach non-standard accelerators. Our **AISS
(AI-instruction Set Sub-extension)** occupies `custom-0` with `funct7 = 0x0A`:

| Instruction | funct3 | Meaning (all f32, element count / dims in integer regs) |
|-------------|--------|----------------------------------------------------------|
| `ai.add`    | 0      | vector add: `dst[i] = srcA[i] + srcB[i]` |
| `ai.relu`   | 1      | vector ReLU: `dst[i] = max(0, srcA[i])` |
| `ai.mul`    | 2      | vector multiply: `dst[i] = srcA[i] * srcB[i]` |
| `ai.matmul` | 3      | matrix multiply: `dst[M×N] = A[M×K] @ B[K×N]` |

**Encoding** (standard R-type layout):

```
31       25 24    20 19    15 14  12 11     7 6      0
[ funct7 ][  rs2  ][  rs1  ][funct3][  rd   ][opcode ]
[ 0x0A   ][        operand select          ][ 0x0B  ]
```

**Register convention** (set up by the compiler immediately before each `.word`):

| Register | Role |
|----------|------|
| `x5`  (`t0`) | element count (add / relu / mul) |
| `x6`  (`t1`) | pointer to source A |
| `x7`  (`t2`) | pointer to source B |
| `x28` (`t3`) | pointer to destination |
| `x29` (`t4`) | matmul M |
| `x30` (`t5`) | matmul K |
| `x31` (`t6`) | matmul N |

Example — `ai.matmul` with A=x6, B=x7, dst=x28, 4×4×4:

```
li   t0, 4          # (count unused by matmul)
mv   t1, a0         # A
mv   t2, a1         # B
addi t3, sp, -144  # dst
li   t4, 4          # M
li   t5, 4          # K
li   t6, 4          # N
.word 0x1c73eb0b    # custom-0 / funct7=0x0A / funct3=3  ->  ai.matmul
```

(You can see these `.word` encodings in every compiled demo: `make dump-demo1`.)

---

## 3. Custom instructions implemented in the compiler infrastructure

The `ai-compiler` recognizes exactly this op set. Every op has **two lowerings**:
`-O1` → one custom-0 AISS instruction (AI hardware datapath), `-O0` → plain
RV64IMAFD scalar loops (software fallback). Both paths are bit-identical and
tested (see `make test`).

| # | Dialect op | Type | `-O1` (hardware) | `-O0` (software) | Tested by |
|---|------------|------|------------------|------------------|-----------|
| 1 | `"ai.add"` | tensor<8xf32> | `ai.add` (custom-0, f3=0) | `flw`/`fadd.s`/`fsw` loop | demo1, demo3 |
| 2 | `"ai.relu"` | tensor<8xf32> | `ai.relu` (custom-0, f3=1) | `flw`/`flt.s`+select/`fsw` loop | demo1, demo3 |
| 3 | `"ai.mul"` | tensor<8xf32> | `ai.mul` (custom-0, f3=2) | `flw`/`fmul.s`/`fsw` loop | demo1 |
| 4 | `"ai.matmul"` | tensor<4x4xf32> | `ai.matmul` (custom-0, f3=3, M/K/N in t4/t5/t6) | triple-loop with `fmadd.s` accumulation | demo2, demo3 |

**Basic (scalar) ops** the compiler also accepts — the glue needed to build and
feed the custom instructions:

| Dialect op | Lowering |
|------------|----------|
| `arith.constant` (f32) | `li` + `fmv.w.x` into a scalar stack slot |
| `arith.addf` / `arith.mulf` (scalar f32) | `flw`/`fadd.s`·`fmul.s`/`fsw` between stack slots |
| `ai.return` | copy the result tensor slot to `OUT` (`flw`/`fsw` loop) and `ret` |

Structural forms parsed by the frontend: `ai.func @name(...)` with typed
tensor arguments, `"ai.op"(%t) : (type) -> type` calls, and `ai.entry @name`.

The full binary encoding, register ABI, and semantics of the four custom
instructions are specified in `docs/riscv-aiss-spec.md`.

---

## 4. Compiler pipeline

```
                 MLIR-style AI dialect              plain RISC-V assembly
  demos/*.aiir  ─────────────────────▶  build/*.kernel.s  ──▶  gcc  ──▶  ELF  ──▶  rvss
  (ai.add / ai.mul / ai.relu /      ai-compiler                                   (chip simulator:
   ai.matmul, arith.* scalars)      [-O1: .word custom-0                          ISS decodes AISS
                                     [-O0: scalar RV64IMAFD                        ops on the AI unit)

  LLVM IR (.ll)  ──────────────────▶  build/*.s  ──▶  llvm-mc / clang  ──▶  ELF  ──▶  rvss
  llvm.riscv.ai.* intrinsics         llc -march=riscv64 -mattr=+xai               (same AI unit;
                 or ai.add t3,t1,t2    [-march=rv64gc_xai]                         byte-identical 0x14730e0b)
                 or raw .word 0x...    llvm-mc --show-encoding
```

* **`-O1` (used by the demos)** — each AI op becomes one *custom-0* instruction, i.e. the
  tensor work happens on the simulated AI hardware datapath in a single instruction.
* **`-O0`** — the same AI ops are lowered to ordinary scalar RV64IMAFD loops
  (`flw` / `fadd.s` / `fsw`, `fmadd.s`), which shows the *fallback software path* every
  real custom-extension chip must provide.
* The **basic instructions** needed to implement the custom ones (address arithmetic,
  `li`/`mv` for the register convention, stack slots for intermediate tensors, copy-back
  loops) are ordinary RV64IMAFD instructions emitted by the compiler.

Kernel ABI (produced for every demo): `void ai_kernel(const float *A, const float *B, float *OUT)`.

---

## 5. The chip simulator (`rvss`)

* Loads the RISC-V ELF (own tiny ELF loader, section headers → RAM at `0x80000000`).
* Implements the instruction subset listed in §2 and **the 4 AISS instructions**:
  opcode `0x0B` is decoded and dispatched to the simulated AI unit
  (`ai_vadd`, `ai_vrelu`, `ai_vmul`, `ai_matmul` in `rvss.c`).
* Reads the `tohost` symbol for semihosting after every retired instruction:
  * `tohost[0] = 1` → exit(0)
  * `tohost[0] = 2` → exit(`tohost[1]`)
  * `tohost[0] = 3` → write `tohost[2]` bytes from `tohost[1]` to stdout
* Useful environment switches: `RVSS_AI_TRACE=1` (print every custom AI op's real
  inputs and output as it executes — shows the intermediate results between chained
  ops), `RVSS_TRACE=1` (dump the last 256 instructions on
  abnormal exit), `RVSS_MAX=n` (instruction budget), `RVSS_BRK=0xADDR` (dump all
  registers when PC hits an address).

---

## 6. Demos and expected results

Every demo ships **its own input numbers** on a `; @operands:` comment line at the top of
`demos/demoN.aiir`, next to a verbatim copy of the three lines the demo prints. Those
comments are checked against the real `./rvss` output on every `make test`
(`tests/oracle.py`), so they cannot go stale. `runtime/driver.c` only supplies a *fallback*
pair (`A = [1,-2,3,-4,…,16]`, `B = 2 × identity`) for a kernel that has no line of its own,
e.g. the ad-hoc `my_kernel` in `setup.md`.

```
Demo     A (operand) printed         B (operand) printed         OUT (result) printed
 demo1   2 -3 4 -5 6 -7 8 -9         10 20 30 40 50 60 70 80     24 0 136 0 336 0 624 0
 demo2   1 2 3 4 5 6 7 8             5 0 0 0 0 -2 0 0            5 -4 12 4 25 -12 28 8
 demo3   1 2 3 4 5 6 7 8             3 0 0 0 0 -2 0 0            6 0 6 32 30 0 14 64
 demo4   -1 2 -3 4 -5 6 -7 8         10 20 30 40 50 60 70 80     0 44 0 176 0 396 0 704
 demo5   -11 12 -13 14 -15 16 -17 18 1 2 3 4 5 6 7 8             0 36 0 70 0 112 0 162
 demo6   1 -2 3 -4 5 6 -7 8          2 0 0 0 0 3 0 0             4 0 12 0 10 21 0 40
 demo7   1 2 3 4 5 6 7 8             1 0 2 0 3 0 4 0             30 0 70 0 0 0 0 0
 demo8   10 20 30 -40 -50 -60 70 80  2 0 0 0 0 2 0 0 (fallback)  120 400 900 1600 2500 3480 4900 6400
```

demo2/demo3/demo6 hold a 4×4 tile (16 lanes) in memory but the driver prints 8; demo8 reuses
demo1's kernel on different data. Full per-demo detail: `files.md` §4 and each file's header.

Run them with (see `setup.md` for the full command list):

```bash
make clean && make
make demo1 && make demo2 && make demo3
```

Each demo's `OUT` is the result of **several** operations chained together (e.g.
`demo1 = relu((A+B)*A)`). The default run only prints the final `OUT`. To see every
intermediate vector — the exact inputs and result of each AI instruction, in order —
add `RVSS_AI_TRACE=1`:

```bash
RVSS_AI_TRACE=1 ./rvss build/demo1.elf      # step-by-step add -> mul -> relu
bash tests/unit/show.sh demo1 hw trace      # same, with a labelled banner
```

### Changing any demo's input numbers on the fly

`tests/set-operands.sh` rewrites a demo's `; @operands:` line, rebuilds only that demo,
runs it and cross-checks the new output against the oracle — so the printed `OUT` always
follows the inputs you supply:

```bash
make set-demo1 OPERANDS="1 1 1 1 1 1 1 1 0 0 0 0 0 0 0 0 2 2 2 2 2 2 2 2 0 0 0 0 0 0 0 0"
bash tests/set-operands.sh demo2 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16  1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1
```

Slots 0..15 become `A`, slots 16..31 become `B`; anything you leave out keeps `driver.c`'s
stock value, so `make set-demo8 OPERANDS="10 20 30 -40 -50 -60 70 80"` is a legal partial
override (it replaces A's first 8 lanes only). Values may be negative or fractional
(`-2.5` prints as `-2.500`, exactly like `print_float()`). The tool rewrites the demo's own
header comments from the new effective vectors, so nothing in the `.aiir` or in the test
suite is left describing the old numbers.

`make test` does **not** hardcode the eight demos' numbers any more: the expected `A`, `B`
and `OUT` strings are recomputed from each `.aiir` by `tests/oracle.py --expect <demo>`, so
the suite stays green (and still exact) after an operand change, in both `-O1` and `-O0`
paths.

Editing by hand works exactly as well — the `; @operands:` line is the only one the compiler
reads; the rest is bookkeeping the tool automates:

```bash
# 1. change the numbers in demos/demo1.aiir (slots 0..15 = A, 16..31 = B)
#    ; @operands: 0x444F5031 1 1 1 1 1 1 1 1 ... 2 2 2 2 2 2 2 2 ...
# 2. update the two `A = [...]` / `B = [...]` comment lines next to it, or let the tool do it
# 3. rebuild + run + verify
make build/demo1.elf && make demo1
python3 tests/oracle.py demo1
```

```bash
python3 tests/oracle.py            # check every demo
python3 tests/oracle.py demo4      # check just one
python3 tests/oracle.py --expect demo4   # print what demo4 should output
```

Any header comment line that quotes the previous numbers in prose (for example
`(B = diag(2,3,4,5))` or `lane 5 is 3, not 2`) cannot be regenerated safely, so the tool
either drops a trailing note or lists the line under `review these header lines:` for a
manual edit — it never leaves one silently contradicting the new inputs.

### 5-stage instruction pipeline diagram

`make demoN` also renders a textbook IF/ID/EX/MEM/WB space-time diagram of that demo's
AI instruction chain to `build/demoN_pipeline.png` — an **Execution Clock** waveform row
with numbered cycles on top, one row per AI op, and data-hazard stalls shown as grey
`stall` bubbles:

```bash
make demo1                 # run the demo AND write build/demo1_pipeline.png
make pipeline-demo3        # just (re)render the picture, no rebuild/run
make pipeline-all          # every demo at once
```

`tools/pipeline_diagram.py` reads the op chain straight from `demos/demoN.aiir` (the same
`%2 = "ai.add"(%0,%1)` SSA the compiler consumes) and models an in-order, single-issue
pipeline with **no forwarding**: a consumer stalls until its producer has reached WB,
matching the stack-slot hand-off the `-O1` kernel uses. Chained demos (1/3/4/5/6/8)
therefore show stalls; the single-matmul demos (2/7) are one clean diagonal. Rendering
needs `python3` + `matplotlib` (`make demoN` skips the picture with a note if it is
absent). It is a pure offline teaching aid and does **not** touch `rvss`, which stays a
functional (untimed) model of *what* the datapath computes.

---

## 7. Repository layout

```
.
├── ai-compiler.c        # AI-dialect → RISC-V compiler (one file)
├── rvss.c               # RISC-V RV64IMAFD + AISS simulator (one file)
├── runtime/
│   ├── crt0.s           # startup code
│   ├── riscv64.ld       # linker script (RAM @ 0x80000000)
│   ├── runtime.c        # tohost semihosting (print/exit)
│   └── driver.c         # bare-metal main() for the demos
├── demos/
│   ├── demo1.aiir       # add -> mul -> relu
│   ├── demo2.aiir       # 4×4 matmul
│   ├── demo3.aiir       # tiny MLP layer (composition)
│   └── ... demo8.aiir   # non-square matmul, reversed chains, operand overrides
│                        # each .aiir carries its own `; @operands:` line
├── llvm-project/llvm/lib/Target/RISCV/
│   ├── RISCVInstrInfoAI.td  # XAi extension: AI_*_IMPLICIT (fixed regs) + generic ai.add/mul/relu/matmul
│   ├── RISCVInstrFormats.td # RVInstR base (OPC_CUSTOM_0=0x0B)
│   └── RISCV.td             # +include RISCVInstrInfoAI.td
├── llvm-project/llvm/include/llvm/IR/IntrinsicsRISCV.td # int_riscv_ai_add/relu/mul/matmul
├── llvm-build/bin/clang|llc|llvm-mc|llvm-objdump  # Release RISCV-only build (XAi)
├── Makefile
├── tests/run-tests.sh       # end-to-end demo test suite (make test)
├── tests/set-operands.sh    # change a demo's operands, rebuild, run, verify (make set-demoN)
├── tests/oracle.py          # independent Python model of every demo (--expect, per-demo args)
├── tests/unit/run-unit.sh   # Phase 1+2 per-instruction unit tests (also in make test)
├── tests/unit/unit_driver.c # bare-metal driver for the unit tests
├── tests/unit/ref.c         # independent host reference for the unit tests
├── tools/pipeline_diagram.py # 5-stage IF/ID/EX/MEM/WB diagram from a demo's .aiir (make demoN / pipeline-all)
├── docs/riscv-aiss-spec.md  # AISS custom-0 ISA extension spec (now with XAi LLVM mapping)
├── architecture.md      # Block diagram & microarchitecture specification
├── README.md            # this file
└── setup.md             # exact terminal commands to build & test (now with LLVM build)
```

---

## 8. Notes & limitations

* The demos build with `-march=rv64imafd -mno-relax` and are linked static/bare-metal;
  the simulator executes the full RV64IMAFD set (including A atomics) but not
  compressed (RVC) instructions, which the kernels opt out of via `.option norvc`.
* `print_float` prints fixed-point `d.ddd` (no printf in the freestanding runtime).
* The AI unit is functional (bit-exact f32 add/mul/relu/matmul) but not pipelined —
  it models *what* the datapath computes, not its timing.
* The natural next step — wiring this same dialect through real MLIR/LLVM
  (`custom-0` intrinsic lowering) — is now **implemented** (`XAi` `llvm.riscv.ai.*` + `llc -mattr=+xai` emit byte-identical `.word` to `ai-compiler`; see `TEST_RESULTS.md` §3–4). The `.aiir` syntax was chosen to map 1:1 onto MLIR's `ai` dialect so migration is mechanical.
* Per-instruction correctness is verified by `tests/unit/run-unit.sh`: each custom op is tested **alone** (`ai.add/mul/relu` at N=4/8/16 and again on a 4×4 result type; `ai.matmul` at 1x1x1…4x4x4 and 2x4x2) and in chains, with hardware `-O1` == software `-O0` == an independent host reference, plus `llvm-mc`/`objdump` encoding checks. `make test` runs the demos (102 PASS) and this campaign (35 PASS). See `TEST_RESULTS.md` §9.
