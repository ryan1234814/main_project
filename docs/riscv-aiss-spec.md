# AISS — AI-instruction Set Sub-extension (custom-0 ISA spec)

A minimal RISC-V **custom extension** specification, written against the
RISC-V Unprivileged ISA (Volume 1) instruction-encoding rules. It occupies the
**`custom-0` major opcode (`0x0B`)** — the opcode space the spec reserves for
per-implementation custom extensions — with `funct7 = 0x0A`.

This is the exact encoding emitted by `ai-compiler -O1` and decoded by `rvss`.

## Instructions

All four operate on **f32** tensors in RAM. Operand addresses are 64-bit
register values; the element count / matrix dims come from integer registers.
No memory faults are signalled (the hardware would use PMP-like checks; the
simulator traps on out-of-RAM accesses).

| funct3 | Mnemonic   | Operation (elementwise over `n` or matmul M×K @ K×N) |
|-------:|------------|-------------------------------------------------------|
| 0      | `ai.add`   | `dst[i] = A[i] + B[i]`                                |
| 1      | `ai.relu`  | `dst[i] = max(0, A[i])`                               |
| 2      | `ai.mul`   | `dst[i] = A[i] × B[i]`                                |
| 3      | `ai.matmul`| `dst[m,n] = Σ_k A[m,k] × B[k,n]`                      |

## Encoding (R-type)

```
 31       25  24    20  19    15  14  12  11     7  6      0
┌───────────┬─────────┬─────────┬───────┬─────────┬─────────┐
│ funct7    │  rs2    │  rs1    │funct3 │   rd    │ opcode  │
│ 0x0A      │ (unused)│ (unused)│  op   │(unused) │ 0x0B    │
└───────────┴─────────┴─────────┴───────┴─────────┴─────────┘
```

* `funct7 = 0x0A` distinguishes AISS from other users of `custom-0`.
* `rd/rs1/rs2` fields are **not** used for register operands — the ABI below
  uses fixed registers so one `.word` can encode a whole tensor operation
  with arbitrarily many elements. (A future revision may multiplex operand
  banks through these fields.)
* Assembly syntax used by the standalone compiler is a raw `.word`; the canonical
  assembler mnemonic would be e.g. `ai.add x28, x6, x7` (informational only).
  **With the LLVM `XAi` extension** (`-march=rv64gc_xai` / `-mattr=+xai` at `llvm-project/llvm/lib/Target/RISCV/RISCVInstrInfoAI.td`), both `ai.add t3,t1,t2` (generic `GPR` form) and the fixed-register `ai.add` (via `call void @llvm.riscv.ai.add()`, `Defs=[X28] Uses=[X5,X6,X7]`) are recognized by `llvm-mc`/`llc`/`clang` and encode byte-identically to the standalone `.word` (`0x14730e0b` etc., verified `llvm-mc --show-encoding` / `riscv64-unknown-elf-objdump -d`).

## Register ABI (fixed by the compiler, honoured by the hardware/AI unit)

| Register | ABI name | Role |
|----------|----------|------|
| `x5`  | `t0` | element count `n` (add/relu/mul) |
| `x6`  | `t1` | address of source A |
| `x7`  | `t2` | address of source B (unused by relu) |
| `x28` | `t3` | address of destination |
| `x29` | `t4` | matmul M (rows of A) |
| `x30` | `t5` | matmul K (cols of A / rows of B) |
| `x31` | `t6` | matmul N (cols of B) |

`t0`–`t6` are caller-saved temporaries in the standard ABI, so the AI unit
needs no additional architectural state and requires no context-switch
support.

## Memory layout rules

* Tensors are tightly packed f32 (4-byte) arrays, row-major for matmul.
* In-place operation is allowed only when `dst == A` (not `dst == B`).
* Address alignment: 4-byte for elementwise ops; 16-byte recommended for
  matmul rows (not enforced by the simulator).

## Semantic notes

* Arithmetic is IEEE-754 binary32, round-to-nearest-even (simulated exactly
  by host `float` ops in `rvss.c`).
* ReLU treats `-0.0` as `0.0`; NaN inputs propagate as NaN.
* No flags, no FP exceptions, no CSRs — AISS is side-effect-free apart from
  the destination memory writes.

## Example

`C = relu(A + B)` on 8 elements:

```asm
li   t0, 8          # n
mv   t1, a0         # A
mv   t2, a1         # B
addi t3, sp, -16    # tmp
.word 0x14730e0b    # ai.add   dst=t3, A=t1, B=t2
li   t0, 8
addi t1, sp, -16    # A = tmp
mv   t2, a0
addi t3, sp, -80    # dst
.word 0x14732e0b    # ai.mul   dst=t3, A=t1, B=t2
li   t0, 8
addi t1, sp, -80
addi t3, sp, -144
.word 0x14031e0b    # ai.relu  dst=t3, A=t1
```

(the exact demo1 sequence — see `build/demo1.kernel.s`)

## Provenance / compatibility & LLVM XAi mapping

* `custom-0` (`0x0B`) is reserved by the RISC-V spec for exactly this purpose;
  Berkeley **Rocket**, **BOOM**, and the reference simulator **Spike** all
  route it to a per-core custom decoder, so this extension style is portable
  to real open-source cores.
* The rest of the machine is a strict **RV64IMAFD** subset — see README §2.
* **LLVM integration:** The `XAi` extension (`-march=rv64gc_xai`, `RISCVExtension<1,0>` at `RISCVInstrInfoAI.td: FeatureVendorXAi`, `HasVendorXAi`) is the upstream-realizable name for this spec. Encoding tables are `RVInstR<0x0A,funct3,OPC_CUSTOM_0>` (`RISCVInstrFormats.td:347`) with hard-wired `rd=28 rs1=6 rs2=7` for the fixed-register form. Intrinsics `llvm.riscv.ai.add/relu/mul/matmul` at `llvm/IR/IntrinsicsRISCV.td` select `AI_*_IMPLICIT` via `Pat` (`RISCVInstrInfoAI.td:66`). TableGen emits `RISCVGen*` inc files; `llvm-build/bin/clang|llc|llvm-mc --mattr=+xai` emit the same `0x14730e0b`/`0x14031e0b`/… bytes as the standalone compiler.

## Verification status

* Supported lengths: elementwise `ai.add/mul/relu` handle any `n` up to the
  simulator's VLEN limit (32); `ai.matmul` handles `MxK * KxN` with `M*N<=16`
  and `K<=16` (the demo limit). The tensor element count comes from the
  `tensor<...>` type in the `.aiir` source.
* Verified by `tests/unit/run-unit.sh` (`make test`): each op tested alone
  (`ai.add/mul/relu` at N=4,8,16; `ai.matmul` at 1x1x1, 2x2x2, 3x3x3, 4x4x4 and
  the non-square 2x4x2) and in chains, with hardware `-O1` == software `-O0` ==
  an independent host reference. ReLU of `[-2, 3, -0.0]` yields `[0, 3, 0]`.
  Recorded in `TEST_RESULTS.md` §9.
