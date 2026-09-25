# viva.md — Viva Questions & Answers (with file paths, functions & line numbers)

> A study sheet of likely viva questions about this project. Every answer is written in simple
> English and then backed up with **exactly which file, which function, and which lines** the
> feature lives on, plus a note on **whether it is actually implemented**.
>
> Line numbers refer to the current files: `ai-compiler.c` (342 lines), `rvss.c` (645 lines),
> `runtime/driver.c` (48), `runtime/runtime.c` (51), `runtime/crt0.s` (10), `runtime/riscv64.ld`
> (28), `Makefile` (65), `tests/run-tests.sh` (57), `tests/unit/show.sh` (110),
> `tests/unit/run-unit.sh` (186), `tests/unit/ref.c` (80).

---

### Q1. What is this project, in one sentence?
**Answer:** We added 4 custom AI instructions to a normal RISC-V chip, wrote a small compiler
that produces them and a simulator that runs them, and proved the answers are exactly correct.
**Where in code:** the two core programs are `ai-compiler.c` (`main()` line 220) and `rvss.c`
(`main()` line 624). **Implemented?** Yes — this whole repo is that proof.

### Q2. What are the 4 custom instructions and their machine encodings?
**Answer:** `ai.add` = `0x14730e0b`, `ai.mul` = `0x14732e0b`, `ai.relu` = `0x14031e0b`,
`ai.matmul` = `0x14733e0b`. Only a few bits differ, which is what picks the operation.
**Where in code:** listed in `tests/unit/show.sh` lines 33–40; produced by `ai_enc()` in
`ai-compiler.c` lines 47–50. **Implemented?** Yes.

### Q3. How is a custom instruction encoded, and why is the number built that way?
**Answer:** It is a normal R-type 32-bit word. We set `opcode = 0x0B` (the lowest 7 bits),
`funct7 = 0x0A` (the top 7 bits), and `funct3` (bits 12–14) selects which op it is (0=add,
1=relu, 2=mul, 3=matmul).
**Where in code:** `ai_enc()` in `ai-compiler.c` lines 47–50:
`(0x0A<<25) | (rs2<<20) | (rs1<<15) | (f3<<12) | (rd<<7) | 0x0B`.
**Implemented?** Yes.

### Q4. Why did you choose opcode `0x0B`?
**Answer:** The RISC-V specification reserves the `0x0B` opcode ("custom-0") for exactly this —
a customer's own private instructions — so our instructions can never collide with real RISC-V
ones.
**Where in code:** explained in the header comment of `rvss.c` lines 14–20, and handled in
`step()` at `case 0x0B` line 575. **Implemented?** Yes.

### Q5. Which registers do the custom instructions use, and what for?
**Answer:** By convention: `t0`(x5)=number of elements (VLEN), `t1`(x6)=pointer to A,
`t2`(x7)=pointer to B, `t3`(x28)=pointer to the destination; for matmul `t4`(x29)=M,
`t5`(x30)=K, `t6`(x31)=N.
**Where in code:** the compiler fills them in `hw_elementwise()` `ai-compiler.c` lines 131–139
and `hw_matmul()` lines 189–199; the simulator reads them in `rvss.c` lines 584–587
(`x[5]`, `x[6]`, `x[7]`, and `x[29] x[30] x[31]`). **Implemented?** Yes.

### Q6. What are the two "paths" (hardware vs software) and why keep both?
**Answer:** The same AI step can be emitted two ways: `-O1` hardware (one special `.word` per
step) and `-O0` software (an ordinary loop). We keep both so we can check they agree — that
agreement is our correctness proof.
**Where in code:** hardware `hw_elementwise()` lines 131–139 / `hw_matmul()` lines 189–199;
software `sw_elementwise()` lines 102–129 / `sw_matmul()` lines 142–186 (all in `ai-compiler.c`).
**Implemented?** Yes, both.

### Q7. How does the software matmul actually work without special instructions?
**Answer:** Three nested loops (i, j, k). For each output cell it multiplies-and-accumulates
using the normal float fused-multiply-add instruction until the row×column sum is complete.
**Where in code:** `sw_matmul()` in `ai-compiler.c` lines 142–186; the key line is
`fmadd.s ft1, fa0, fa1, ft0` at line 170. **Implemented?** Yes.

### Q8. How does the compiler understand the input `.aiir` file?
**Answer:** It reads it line by line, strips comments, finds each temporary (`%n`), and reads the
tensor shape (like `tensor<8xf32>`) to learn how many elements there are.
**Where in code:** `rstrip_comments()` lines 53–57, `temp_of()` lines 58–65, and `parse_dims()`
lines 72–90 in `ai-compiler.c`. **Implemented?** Yes.

### Q9. What is `parse_dims()` and what bug did it once have?
**Answer:** It turns `tensor<16xf32>` into the number 16. The old bug: it counted the `32` inside
`f32` as a second dimension, so size-16 tensors got truncated to 8. Fixed by only treating
`x`-separated tokens made entirely of digits as dimensions.
**Where in code:** `parse_dims()` `ai-compiler.c` lines 72–90 (the digit-check loop lines 82–86).
**Implemented?** Yes, fixed.

### Q10. What is `rvss.c` and what does its main loop do?
**Answer:** It is the simulator (a program that pretends to be the chip). Its main loop repeatedly
**fetches** the next instruction, **decodes** it, and **executes** it, until the program asks to
stop.
**Where in code:** `step()` in `rvss.c` line 271 (the big `switch` over the opcode), driven by the
loop in `main()` starting line 636. **Implemented?** Yes.

### Q11. How does the simulator recognize and run a custom AI instruction?
**Answer:** In `step()`, when the low opcode bits equal `0x0B`, it looks at `funct3` and calls the
matching AI routine (add/relu/mul/matmul) with the register operands.
**Where in code:** `rvss.c` `case 0x0B` lines 575–588; the dispatch is lines 584–587.
**Implemented?** Yes.

### Q12. Where is the AI math itself (the add/mul/relu/matmul operations) done?
**Answer:** In four small functions that read floats from simulated memory, compute, and write
back.
**Where in code:** `ai_vadd()` line 91, `ai_vmul()` line 99, `ai_vrelu()` line 107,
`ai_matmul()` line 115 (all in `rvss.c`). **Implemented?** Yes.

### Q13. How does the simulator model memory?
**Answer:** It just `calloc`s a big 8 MB array and pretends that is RAM, starting at address
`0x80000000`. Reading/writing that address range is translated into array access.
**Where in code:** `RAM_BASE`/`RAM_SIZE` `rvss.c` lines 36–38; `load()` line 70, `store()` line
76; the array is allocated in `main()` line 626. **Implemented?** Yes.

### Q14. There is no operating system — so how does the program print numbers and stop?
**Answer:** Through a tiny "note in memory" handshake called the **tohost mailbox**. The program
writes a command into a shared variable; the simulator notices it and either prints text or exits.
**Where in code:** the mailbox is `volatile uint64_t tohost[4]` in `runtime/runtime.c` line 11;
`print_str()` line 17 uses `SYS_WRITE` (0x03, line 14) and `exit_sim()` line 46 uses `SYS_EXIT`
(0x02, line 15). The simulator services it in `do_tohost()` `rvss.c` line 236, polled each step
(`rvss.c` lines 464 and 639). **Implemented?** Yes.

### Q15. How is a float printed when there is no `printf`?
**Answer:** The number is split into a whole part and a fractional part using plain integer math,
then each is printed digit by digit.
**Where in code:** `print_float()` in `runtime/runtime.c` lines 38–44 (calls `print_int()` line
27). **Implemented?** Yes.

### Q16. How does execution actually begin at the right place?
**Answer:** A tiny assembly file is the entry point: it loads the global-pointer and stack-pointer
registers and then calls `main`.
**Where in code:** `runtime/crt0.s` lines 3–10 — `la gp` (5), `la sp, _stack_top` (6),
`call main` (7), then a `wfi` idle loop (8). **Implemented?** Yes.

### Q17. Who decides that RAM is at `0x80000000` and where the stack is?
**Answer:** The linker script lays out memory: it places the program at `0x80000000` and reserves
a stack at the top of the 8 MB. The simulator's `RAM_BASE` is set to match it.
**Where in code:** `runtime/riscv64.ld` — `RAM ... ORIGIN = 0x80000000, LENGTH = 8M` line 7,
`.text` line 13, `__global_pointer$` line 16, `_stack_top` line 27. **Implemented?** Yes.

### Q18. What does the demo `main()` do?
**Answer:** It prints the two input arrays, calls the generated `ai_kernel(A, B, OUT)`, prints the
result, and exits. It uses fixed inputs so the expected answer is always the same.
**Where in code:** `runtime/driver.c` — the print helpers are declared lines 11–13, the kernel
prototype line 16, and the fixed `A[16]` array line 18. **Implemented?** Yes.

### Q19. What is the `RVSS_AI_TRACE` feature and does it work on both paths?
**Answer:** Setting `RVSS_AI_TRACE=1` makes the simulator print every custom AI instruction's real
inputs and output as it runs, so you can watch intermediate results. It is **hardware-path only** —
the `-O0` software build contains no custom words, so there is nothing for it to trace (and
`show.sh` says so politely).
**Where in code:** enabled by `getenv("RVSS_AI_TRACE")` in `rvss.c` line 628; the recorder
`trace_step()` line 56 and printer `trace_dump()` line 57 / `ai_trace_vec()` line 131; the
graceful "no custom .word" message is in `tests/unit/show.sh`. **Implemented?** Yes (hw only).

### Q20. How do you prove the custom instructions are correct?
**Answer:** Three-way agreement: the `-O1` hardware result must equal the `-O0` software result,
and both must equal an **independent** reference answer computed in plain C. The reference is
important because two paths sharing one bug would still agree with each other.
**Where in code:** the reference is `tests/unit/ref.c` (whole file, 80 lines); the comparison
driver is `tests/unit/run-unit.sh`; the demo-level checks are `tests/run-tests.sh`.
**Implemented?** Yes.

### Q21. How many tests are there and how do you run them all?
**Answer:** `make test` runs everything — the 15 demo checks plus the 32 unit checks = 47 passing
checks.
**Where in code:** the `test:` target in the `Makefile` (declared `.PHONY` line 25) calls
`tests/run-tests.sh` and `tests/unit/run-unit.sh`. **Implemented?** Yes.

### Q22. How is the whole thing built?
**Answer:** One `Makefile` builds the two host tools and turns each demo through the pipeline
`.aiir → .s → .o → .elf`.
**Where in code:** `Makefile` — `ai-compiler:` target line 30, `rvss:` target line 33, the per-demo
`DEMO_RULES` from line 37, and assemble/link flags in `MARCH`/`CFLAGS` lines 21–22
(`-march=rv64imafd -mabi=lp64`, `-ffreestanding -nostdlib`). **Implemented?** Yes.

### Q23. What ISA (chip feature set) do you target and why?
**Answer:** Rocket Chip's **RV64IMAFD** — 64-bit with Integer, Multiply, Atomic, and single/double
Float — a real, common embedded core, which makes the extension more believable than a toy target.
**Where in code:** the flags `MARCH = -march=rv64imafd -mabi=lp64` in `Makefile` line 21; described
in `rvss.c` header lines 14–20. **Implemented?** Yes.

### Q24. Is your idea also proven inside a real compiler, not just your own?
**Answer:** Yes. We patched LLVM's real RISC-V backend to add the same 4 instructions, and it
emits byte-identical encodings. This shows the design would fit an industry toolchain.
**Where in code:** `llvm-xai.patch` edits three files under `llvm-project/`:
`RISCVInstrInfoAI.td` (new), `RISCV.td` (include), and `IntrinsicsRISCV.td` (intrinsic
declarations); enabled with `-mattr=+xai`. **Implemented?** Yes.

### Q25. What is the single most important takeaway of the project?
**Answer:** A custom AI instruction and the ordinary loop that mimics it must produce **exactly
the same numbers** — the whole project exists to build those instructions, run them, and prove
that equality.
**Where in code:** both lowerings live side by side in `ai-compiler.c` (`hw_*` vs `sw_*`,
lines 102–199) and the equality is enforced by `tests/unit/run-unit.sh` + `tests/unit/ref.c`.
**Implemented?** Yes.

---

## Quick index — where each feature is implemented

| Feature | File | Function / marker | Lines |
|---|---|---|---|
| Custom instruction encoding | `ai-compiler.c` | `ai_enc()` | 47–50 |
| Read shapes / parse input | `ai-compiler.c` | `parse_dims()`, `temp_of()` | 72–90, 58–65 |
| Hardware (-O1) lowering | `ai-compiler.c` | `hw_elementwise()`, `hw_matmul()` | 131–139, 189–199 |
| Software (-O0) lowering | `ai-compiler.c` | `sw_elementwise()`, `sw_matmul()` | 102–129, 142–186 |
| Copy result to OUT | `ai-compiler.c` | `emit_return()` | 202–217 |
| Simulate memory (8 MB @ 0x80000000) | `rvss.c` | `RAM_BASE`, `load()`, `store()` | 36–38, 70, 76 |
| AI datapath | `rvss.c` | `ai_vadd/vmul/vrelu/matmul` | 91, 99, 107, 115 |
| Decode custom-0 | `rvss.c` | `step()` `case 0x0B` | 271, 575–588 |
| Semihosting mailbox | `runtime/runtime.c` + `rvss.c` | `print_str/float`, `do_tohost()` | 11–49; 236 |
| Step-by-step trace | `rvss.c` + `show.sh` | `RVSS_AI_TRACE`, `trace_dump()` | 48–57, 628 |
| Entry point / layout | `runtime/crt0.s`, `riscv64.ld` | `_start`, `RAM ORIGIN` | 3–10; 7–27 |
| Correctness (hw==sw==ref) | `tests/unit/*`, `tests/run-tests.sh` | `ref.c`, `run-unit.sh` | whole files |
| Real-compiler proof | `llvm-xai.patch` + `llvm-project/` | `RISCVInstrInfoAI.td` | patch |
