# facts.md — Key Facts About How This Code Really Works

> Plain-English answers to specific questions about the implementation, each backed by the
> exact file, function, and line numbers so you can open the code and see it for yourself.

---

## Q1. Is vectorization supported in this code? If yes, where and how?

**Short answer:** There is **no hardware vectorization** — no RISC‑V Vector extension (RVV),
no SIMD, no packed lanes. The chip we target is `rv64imafd`, and that string has **no `v`** in
it. What we *do* have is a **vector-like idea at the instruction level**: one custom AI
instruction carries a *length* and describes an operation over a whole list of numbers — but
under the hood it is still run **one element at a time** in a normal loop.

### 1a. The standard vector extension is NOT there
- The target ISA is set once in the build: `-march=rv64imafd` → [`Makefile` line 21](file:///Users/ryangeorge/llvm/Makefile#L21).
  `I M A F D` = Integer, Multiply, Atomics, Float, Double — no `V`.
- Searching the whole project for `rvv`, `vle.`/`vse.`, `vadd.v`, `simd`, or `rv64imafdv` finds
  nothing. So there are no vector registers, no `vsetvl`, no SIMD instructions anywhere.

### 1b. What looks like "vector" = a length field on a custom op
Each AI instruction is told how many elements to process:
- The compiler puts the count (called **VLEN**) in register `t0` right before the special
  instruction: [`ai-compiler.c` `hw_elementwise()` lines 131–139](file:///Users/ryangeorge/llvm/ai-compiler.c#L131-L139)
  (the `li t0, %d  # VLEN` on line 133). The size is capped at 32 elements for the hardware
  path ([line 132](file:///Users/ryangeorge/llvm/ai-compiler.c#L132)) and 16 for the software
  path ([line 103](file:///Users/ryangeorge/llvm/ai-compiler.c#L103)).
- So at the **ISA level** it reads like SIMD: "one instruction, N data elements."

### 1c. But it actually executes as a plain scalar loop
When the simulator runs that one instruction, it does **not** process the elements in parallel.
It runs a normal C loop, element by element:
- [`rvss.c` `ai_vadd()` lines 91–98](file:///Users/ryangeorge/llvm/rvss.c#L91-L98) — `for (int i = 0;
  i < n; i++) { load A[i]; load B[i]; r = fa + fb; store OUT[i]; }`
- Likewise `ai_vmul()` (99), `ai_vrelu()` (107), `ai_matmul()` (115, three nested loops).
- The software `-O0` path is also a scalar loop of `flw`/`fadd.s`/`fsw`:
  [`ai-compiler.c` `sw_elementwise()` lines 102–129](file:///Users/ryangeorge/llvm/ai-compiler.c#L102-L129).

**Understanding it in one line:** the "vector" is only in the *meaning* of the instruction (it
stands for a whole array of operations); the *implementation* is a scalar loop. It is
**vector semantics, not a vector unit.**

| Meaning of "vectorization" | Present? | Where in code |
|---|---|---|
| RISC‑V V / RVV / SIMD / P‑ext | ❌ No | ISA is `rv64imafd` (no `v`), [Makefile L21](file:///Users/ryangeorge/llvm/Makefile#L21) |
| One instruction → N elements (VLEN) | ⚠️ Yes, but only as semantics | `hw_elementwise()` [L131–139](file:///Users/ryangeorge/llvm/ai-compiler.c#L131-L139) |
| Real parallel hardware datapath | ❌ No — simulated as a loop | `ai_vadd/vmul/vrelu` [rvss.c L91–114](file:///Users/ryangeorge/llvm/rvss.c#L91-L114) |

---

## Q2. How does the compiler decide whether to use normal vs custom-AI instructions?

**Short answer:** It is **not** the compiler being clever about the code — it is a single
command-line switch you choose: `-O1` means "use the custom AI instructions," and `-O0` means
"use normal RV64IMAFD instructions." Internally this is one on/off flag called `emit_hw`, and at
every AI operation the compiler simply branches on it.

### Step 1 — a global on/off flag, default OFF
- [`ai-compiler.c` line 33](file:///Users/ryangeorge/llvm/ai-compiler.c#L33): `static int emit_hw = 0;`
  (0 = software/normal by default).

### Step 2 — the command-line flag sets it
- [`ai-compiler.c` `main()` lines 224–225](file:///Users/ryangeorge/llvm/ai-compiler.c#L224-L225):
  - `-O1` → `emit_hw = 1` (custom hardware path)
  - `-O0` → `emit_hw = 0` (normal software path)

### Step 3 — at each AI operation, the flag picks the lowering
This is the exact "decision point." For every op, the compiler does an if/else on `emit_hw`:
- [`ai-compiler.c` lines 297–304](file:///Users/ryangeorge/llvm/ai-compiler.c#L297-L304):
```c
if (!strcmp(name,"add") || !strcmp(name,"mul") || !strcmp(name,"relu")) {
    int f3 = ...;                                   // which op
    if (emit_hw) hw_elementwise(f3, name, ...);     // custom .word   (line 299)
    else         sw_elementwise(name, ...);         // normal loop   (line 300)
} else if (is_mm) {
    if (emit_hw) hw_matmul(...);                    // custom .word   (line 302)
    else         sw_matmul(...);                    // normal loop    (line 303)
}
```
- `hw_elementwise()` / `hw_matmul()` emit **one custom `.word`** per step
  ([lines 131–139](file:///Users/ryangeorge/llvm/ai-compiler.c#L131-L139) /
  [189–199](file:///Users/ryangeorge/llvm/ai-compiler.c#L189-L199));
  `sw_elementwise()` / `sw_matmul()` emit an **ordinary scalar loop**
  ([102–129](file:///Users/ryangeorge/llvm/ai-compiler.c#L102-L129) /
  [142–186](file:///Users/ryangeorge/llvm/ai-compiler.c#L142-L186)).

### Step 4 — the chosen mode is recorded in the output
- The generated file's header comment and the console message both print which path was taken,
  based on the same flag: [`main()` lines 246–247](file:///Users/ryangeorge/llvm/ai-compiler.c#L246-L247)
  and [lines 338–339](file:///Users/ryangeorge/llvm/ai-compiler.c#L338-L339)
  (`"AISS custom-0 hardware"` vs `"RV64IMAFD software"`).

### How to see it yourself
The same input compiled two ways, and `show.sh` reveals the difference in the `ASSEMBLY` section:
```bash
bash tests/unit/show.sh add4 hw     # -> one .word 0x14730e0b   (custom)
bash tests/unit/show.sh add4 sw     # -> flw/fadd.s/fsw loop     (normal)
```

**Understanding it in one line:** the compiler never "figures out" which to use from the math —
**you tell it with `-O0` or `-O1`**, it stores that in `emit_hw`
([line 33](file:///Users/ryangeorge/llvm/ai-compiler.c#L33)), and every operation is chosen by a
single `if (emit_hw)` branch ([lines 299 & 302](file:///Users/ryangeorge/llvm/ai-compiler.c#L299-L302)).

---

## Why both paths exist (the point behind these two facts)
The two questions touch the same design goal: the **custom** instructions are the fast, compact
version, and the **normal** instructions are the plain fallback. Because the *only* thing that
differs is the `emit_hw` switch, we can compile the same input both ways and require the answers
to match bit-for-bit — that equality is the project's proof that the custom AI instructions are
correct.
