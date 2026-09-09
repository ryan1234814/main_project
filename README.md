# AISS — a tiny RISC-V AI-instruction compiler + ISA simulator demo

This project demonstrates, end to end, how a **custom set of AI instructions** can be
added to the RISC-V ISA, how a **compiler lowers a small MLIR-style AI dialect** onto
those instructions, and how a **RISC-V chip simulator** executes the result — including
the custom instructions on a simulated AI datapath.

Everything is intentionally **minimal**: two small C programs, a bare-metal runtime,
three demo kernels, and a Makefile. No LLVM/MLIR install is required to run the demo
(the input language is an MLIR-*flavoured* text IR, parsed by a ~600-line compiler).

---

## 1. What is in this repo

| File | What it is |
|------|------------|
| `ai-compiler.c` → `ai-compiler` | Compiler: MLIR-style `.aiir` → RISC-V RV64IMAF assembly. `-O1` emits the **custom AI instructions** as raw `.word` encodings; default (`-O0`) lowers the same AI ops to plain scalar RV64IMAF loops. |
| `rvss.c` → `rvss` | RISC-V instruction-set simulator (ISS): decodes and executes RV64IMAF(D-subset) **plus the 4 custom AI instructions** on a simulated AI unit. |
| `runtime/crt0.s` | Bare-metal startup (`_start`: set `gp`/`sp`, call `main`). |
| `runtime/riscv64.ld` | Linker script: everything placed in RAM at `0x80000000`, `_stack_top` on top. |
| `runtime/runtime.c` | Semihosting via the `tohost` mailbox: `print_str`, `print_int`, `print_float`, `exit_sim`. |
| `runtime/driver.c` | The bare-metal `main()` shared by all demos: fills input arrays, calls the compiled `ai_kernel(A, B, OUT)`, prints the results. |
| `demos/demo1.aiir` | Elementwise chain `relu((A+B) ∘ A)` on 8×f32 → exercises `ai.add`, `ai.mul`, `ai.relu`. |
| `demos/demo2.aiir` | 4×4×f32 matrix multiply → exercises `ai.matmul`. |
| `demos/demo3.aiir` | Tiny MLP layer `relu((W·x) + (W·x))` → exercises `ai.matmul` + `ai.add` + `ai.relu` chained on one datapath. |
| `Makefile` | Builds the tools, compiles every demo `.aiir` → `.s` → `.o` → ELF, and runs them on `rvss`. |

---

## 2. Which RISC-V ISA is this? (open-source core provenance)

The simulator implements **a slice of the RISC-V Unprivileged ISA (Volume 1)** — not the
whole ISA, only what is needed to compile and run real bare-metal code plus the custom
AI instructions:

* **RV64I** — all base integer instructions used by `riscv64-unknown-elf-gcc -O2`
  bare-metal output: loads/stores, ALU ops, `lui`/`auipc`, shifts, branches, `jal`/`jalr`,
  64-bit and 32-bit (`*W`) forms.
* **M** — `mul/mulh/mulhu/mulhsu/div/divu/rem/remu` (RV64M).
* **F/D (subset)** — FP loads/stores, `fadd/fsub/fmul/fdiv/fsqrt`, FMA, `fmin/fmax`,
  sign-injection, comparisons, conversions, `fmv.x.w/fmv.w.x`, `fclass` — with the
  RV64 **NaN-boxing** rule for 32-bit floats.
* **Not implemented** (deliberately, to keep the demo small): C (compressed),
  A (atomics), V, bit-manipulation, privileged/CSR.

This is exactly the user-level ISA implemented for `RV64IMAFD` by the well-known
open-source RISC-V cores — **UC Berkeley Rocket** and the official reference simulator
**Spike (riscv-isa-sim)** — so ordinary `riscv64-unknown-elf-gcc` output (built for
`-march=rv64imaf -mabi=lp64 -mcmodel=medany`) runs unmodified.

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
RV64IMAF scalar loops (software fallback). Both paths are bit-identical and
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
                                     [-O0: scalar RV64IMAF                        ops on the AI unit)
```

* **`-O1` (used by the demos)** — each AI op becomes one *custom-0* instruction, i.e. the
  tensor work happens on the simulated AI hardware datapath in a single instruction.
* **`-O0`** — the same AI ops are lowered to ordinary scalar RV64IMAF loops
  (`flw` / `fadd.s` / `fsw`, `fmadd.s`), which shows the *fallback software path* every
  real custom-extension chip must provide.
* The **basic instructions** needed to implement the custom ones (address arithmetic,
  `li`/`mv` for the register convention, stack slots for intermediate tensors, copy-back
  loops) are ordinary RV64IMAF instructions emitted by the compiler.

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
* Useful environment switches: `RVSS_TRACE=1` (dump the last 256 instructions on
  abnormal exit), `RVSS_MAX=n` (instruction budget), `RVSS_BRK=0xADDR` (dump all
  registers when PC hits an address).

---

## 6. Demos and expected results

Inputs live in `runtime/driver.c`:

```
A[16] = 1,-2,3,-4,5,-6,7,-8,9,10,11,12,13,14,15,16
B[16] = 2 0 0 0 / 0 2 0 0 / 0 0 2 0 / 0 0 0 2   (2 × identity)
```

| Demo | Ops used | Expected `OUT` (first 8 values printed) |
|------|----------|------------------------------------------|
| `demo1` | `ai.add`, `ai.mul`, `ai.relu` | `3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0` |
| `demo2` | `ai.matmul` (4×4×4) | `2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0`  (= 2·A) |
| `demo3` | `ai.matmul` + `ai.add` + `ai.relu` | `4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0`  (= relu(4·A)) |

Run them with (see `setup.md` for the full command list):

```bash
make clean && make
make demo1 && make demo2 && make demo3
```

---

## 7. Repository layout

```
.
├── ai-compiler.c        # AI-dialect → RISC-V compiler (one file)
├── rvss.c               # RISC-V RV64IMAF + AISS simulator (one file)
├── runtime/
│   ├── crt0.s           # startup code
│   ├── riscv64.ld       # linker script (RAM @ 0x80000000)
│   ├── runtime.c        # tohost semihosting (print/exit)
│   └── driver.c         # bare-metal main() for the demos
├── demos/
│   ├── demo1.aiir       # elementwise AI ops
│   ├── demo2.aiir       # 4×4 matmul
│   └── demo3.aiir       # tiny MLP layer (composition)
├── Makefile
├── tests/run-tests.sh  # end-to-end test suite (make test)
├── docs/riscv-aiss-spec.md  # AISS custom-0 ISA extension spec
├── architecture.md      # Block diagram & microarchitecture specification
├── README.md            # this file
└── setup.md             # exact terminal commands to build & test
```

---

## 8. Notes & limitations

* The demos build with `-march=rv64imaf -mno-relax` and are linked static/bare-metal;
  the simulator does not implement compressed (RVC) or atomic (A) instructions.
* `print_float` prints fixed-point `d.ddd` (no printf in the freestanding runtime).
* The AI unit is functional (bit-exact f32 add/mul/relu/matmul) but not pipelined —
  it models *what* the datapath computes, not its timing.
* The natural next step is wiring this same dialect through real MLIR/LLVM
  (`custom-0` intrinsic lowering); the `.aiir` syntax was chosen to map 1:1 onto MLIR's
  `ai` dialect form so that migration is mechanical.
