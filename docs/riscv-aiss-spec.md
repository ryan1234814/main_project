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
* Assembly syntax used by the compiler is a raw `.word`; the canonical
  assembler mnemonic would be e.g. `ai.add x28, x6, x7` (informational only).

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
.word 0x14732e0b    # ai.add   ...
li   t0, 8
addi t1, sp, -80
addi t3, sp, -144
.word 0x14031e0b    # ai.relu  dst=t3, A=t1
```

(the exact demo1 sequence — see `build/demo1.kernel.s`)

## Provenance / compatibility

* `custom-0` (`0x0B`) is reserved by the RISC-V spec for exactly this purpose;
  Berkeley **Rocket**, **BOOM**, and the reference simulator **Spike** all
  route it to a per-core custom decoder, so this extension style is portable
  to real open-source cores.
* The rest of the machine is a strict **RV64IMAF** subset — see README §2.
