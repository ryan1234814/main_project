# Workflow — Where the RV64IMAFD ISA Comes From and How the 7 Compiler Stages Work

This file explains two things in simple English: (1) where this project's RISC-V ISA came from, and (2) how each of the 7 classic compiler stages is implemented in this codebase.

---

## Part 1: Where did the RV64IMAFD ISA for this chip come from?

We did **not** invent a new CPU from scratch. We took a standard, open RISC-V design and used only the part we need.

### 1. The base ISA is the official RISC-V Unprivileged ISA (Volume 1)

This is the public specification that defines what every RISC-V CPU must understand. It is maintained by RISC-V International. Anyone can download it for free. Our chip implements a **small slice** of it — just enough to run real `riscv64-unknown-elf-gcc` bare-metal code:

* **RV64I** — base 64-bit integer instructions (loads, stores, `lui`/`auipc`, `add`/`sub`, shifts, branches, `jal`/`jalr`, and 32-bit `*W` forms).
* **M** — multiply/divide (`mul`, `div`, `rem` and variants).
* **F/D (subset for f32)** — floating point for 32-bit floats (`flw`/`fsw`, `fadd.s`, `fsub.s`, `fmul.s`, `fdiv.s`, `fsqrt.s`, `fmadd.s`, `fmin`/`fmax`, comparisons, conversions, `fmv.w.x`, `fclass`) with the RV64 **NaN-boxing** rule.

We left out `C` (compressed), `A` (atomics), `V` (vector), and privileged/CSR instructions to keep the demo small. See `README.md:32` and `rvss.c:7`.

### 2. The exact instructions we support come from two trusted open-source cores

The list above matches exactly what these two well-known open-source RISC-V cores implement for `RV64IMAFD` at user level:

* **UC Berkeley Rocket Chip** — the classic RISC-V core used for teaching and research.
* **Spike (`riscv-isa-sim`)** — the official RISC-V reference simulator.

Because we copied their user-level ISA slice, normal output from `riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany` runs without change. Provenance is documented in `README.md:47` and `docs/riscv-aiss-spec.md:96`.

### 3. The 4 custom AI instructions use the `custom-0` space the spec reserves for you

The RISC-V spec keeps two major opcodes, `custom-0 (0x0B)` and `custom-1 (0x2B)`, empty on purpose so anyone can add their own instructions. Rocket, BOOM, and Spike all do this. Our **AISS (AI-Instruction Set Sub-extension)** uses `custom-0` with `funct7 = 0x0A` — see `README.md:54` and `docs/riscv-aiss-spec.md:1`:

| Instruction | `funct3` | What it does |
|---|---|---|
| `ai.add` | 0 | `dst[i] = A[i] + B[i]` |
| `ai.relu` | 1 | `dst[i] = max(0, A[i])` |
| `ai.mul` | 2 | `dst[i] = A[i] * B[i]` |
| `ai.matmul` | 3 | `C = A @ B` (matrix multiply) |

Encoding is standard R-type (`docs/riscv-aiss-spec.md:24`):

```
31      25 24   20 19   15 14 12 11    7 6     0
[ funct7 ][ rs2  ][ rs1  ][funct3][  rd  ][opcode]
[  0x0A  ][      not used      ][ 0..3 ][  --  ][ 0x0B ]
```

The fields `rd/rs1/rs2` are unused. Instead the compiler sets up fixed registers before each `.word` (`README.md:74`, `ai-compiler.c:16`): `x5(t0)=count`, `x6(t1)=A ptr`, `x7(t2)=B ptr`, `x28(t3)=dst ptr`, `x29/x30/x31 = M/K/N` for matmul. The simulator decodes `opcode 0x0B + funct7 0x0A` in `rvss.c:516` and runs `ai_vadd`/`ai_vmul`/`ai_vrelu`/`ai_matmul` (`rvss.c:79`).

In short: **base ISA from the RISC-V spec via Rocket/Spike, custom AI ops in the spec's own custom-0 slot.**

---

## Part 2: The 7 Stages of the Compiler — In Simple English

Think of the compiler like a translation factory. The `.aiir` file (e.g., `demos/demo1.aiir:8`) is written in a high-level AI language. The factory has 7 stations, each doing one simple job.

### Big picture

```
demos/*.aiir  -->  ai-compiler  -->  build/*.kernel.s  -->  riscv64-unknown-elf-gcc + linker  -->  build/*.elf  -->  rvss
  (AI math)        (stages 1-6)       (assembly)            (stage 7: assemble + link)            (runs it)
```

All of stages 1–6 live inside one file: `ai-compiler.c:1`. Stage 7 is done by the normal RISC-V tools + our simulator.

---

### Stage 1: Lexical Analysis (Breaking text into words)

**In simple words:** Like splitting a sentence into individual words. The compiler reads the file character by character and throws away spaces and comments.

**Where in code:** `ai-compiler.c:53` `rstrip_comments()` removes `; comments`, `ai-compiler.c:224` loop reads each line with `fgets()` into `src[][]:31`, `ai-compiler.c:227` skips spaces, `ai-compiler.c:58` `temp_of()` finds the next `%0` by scanning for `%`, `ai-compiler.c:70` `parse_dims()` scans for `tensor<`.

**Example:** The line `%2 = "ai.add"(%0, %1)` becomes pieces: `%2`, `=`, `"ai.add"`, `%0`, `%1`.

### Stage 2: Syntax Analysis / Parsing (Checking grammar)

**In simple words:** Like checking if a sentence follows grammar rules. Is it `Subject Verb Object`? Here: is it `%result = "ai.op"(inputs) : types -> type`?

**Where in code:** `ai-compiler.c:246` main loop. It checks: does line start with `%` and contain `"ai.`? (`ai-compiler.c:263`), is there a `(` for the operand list (`ai-compiler.c:272` `die("missing operand list")`), is there a `->` for the return type, does `ai.return` exist (`ai-compiler.c:253`). If the pattern is wrong, it stops with an error.

**Example:** `%3 = "ai.mul"(%2, %0)` passes because it matches the expected pattern. `%3 = "ai.mul" %2 %0` would fail.

### Stage 3: Semantic Analysis (Checking meaning)

**In simple words:** Grammar can be correct but meaning wrong — like "the dog drives a car". This stage checks: does this make sense? Is the tensor size allowed? Does the variable exist?

**Where in code:** `ai-compiler.c:63` `temp_of()` checks temp is `0..63` (`MAX_T:29`), `ai-compiler.c:93` `sw_elementwise()` checks `n > 16` (demo limit), `ai-compiler.c:122` `hw_elementwise()` checks `n > 32` (hardware limit), `ai-compiler.c:133` `sw_matmul()` checks `M*N > 16`, `ai-compiler.c:324` checks `no ai.return found`.

**Example:** `tensor<100xf32>` would be rejected because our hardware only handles up to 16 elements. Using `%99` when only `%0..%4` exist would also be an error.

### Stage 4: Intermediate Representation — IR (A simple middle language)

**In simple words:** Before translating to the final language, the compiler keeps the program in a simple, clean internal form. Here the IR is very simple: the list of lines in `src[][]` and the idea of SSA temps `%0, %1, %2...`.

**Where in code:** `ai-compiler.c:31` `src[MAX_LINES][MAX_LEN]` stores every line after lexing. `%0` always means input `A` (`a0`), `%1` is `B` (`a1`), `%2` and above are temporary tensors that live on the stack. Two helper functions define where: `tensor_slot(t):66` `sp - 16 - 64*(t-2)` (64 bytes = 16 floats) and `scalar_slot(t):67` `sp - 1024 - 4*t` (`architecture.md:333` shows the stack picture).

**Example:** `%2 = ai.add(%0,%1)` means: "take the two input tensors, add them, store result in the stack slot for `%2` (at `sp-16`)".

### Stage 5: Optimization (Making it faster, choosing the best path)

**In simple words:** Same meaning, faster execution. This compiler has one simple optimization choice: do we use the AI hardware or normal software loops?

**Where in code:** `ai-compiler.c:33` `emit_hw` flag set by `-O1`/`-O0` (`ai-compiler.c:214`). The `main` loop (`ai-compiler.c:287`) picks:
* `emit_hw == 1` → `hw_elementwise():121` or `hw_matmul():179` — one `.word` instruction does the whole tensor.
* `emit_hw == 0` → `sw_elementwise():92` or `sw_matmul():132` — many normal instructions in a loop.

No other optimizations (like removing unused code) are done, to keep the demo clear. `architecture.md:285` explains the two paths give bit-identical results.

### Stage 6: Code Generation (Writing the final RISC-V assembly)

**In simple words:** Translate the IR into real instructions the chip can read.

**Where in code:** `ai-compiler.c:40` `emit()` writes to the `.s` file. Helpers write the actual assembly:
* `ai_enc():47` builds the 32-bit `.word` for custom ops: `0x0A<<25 | rs2<<20 | rs1<<15 | f3<<12 | rd<<7 | 0x0B`.
* `emit_src():84` writes `mv t1, a0` (if input) or `addi t1, sp, -slot` (if temp).
* `hw_elementwise():123` writes `li t0, n` + `mv t1/t2` + `addi t3, sp, -slot` + `.word 0x...`.
* `sw_elementwise():98` writes `flw fa0, 0(t1)` / `fadd.s fa2, fa0, fa1` / `fsw fa2, 0(t3)` in a `bnez` loop.
* `emit_return():192` copies the final tensor to `OUT` (`a2`) and writes `ret`.
* Header `ai-compiler.c:238` writes `.option norvc` / `.text` / `.globl ai_kernel`.

**Example for `-O1`:** `%2 = ai.add(%0,%1)` with `n=8` becomes 4 lines: `li t0,8`, `mv t1,a0`, `mv t2,a1`, `addi t3,sp,-16`, `.word 0x14730e0b`. For `-O0` the same becomes ~15 lines with a load-add-store loop.

### Stage 7: Assembly, Linking, and Execution (Packing and running)

**In simple words:** The `.s` file is text. It must be turned into a binary (ELF), packed with startup code and runtime, and then run on the chip.

**Where in code — not in `ai-compiler.c` but in the toolchain:**
* **Assemble:** `Makefile:37` `riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mno-relax -c build/demo1.kernel.s -o build/demo1.kernel.o` — turns assembly into machine code.
* **Link:** `Makefile:41` `riscv64-unknown-elf-gcc -T runtime/riscv64.ld -nostdlib -static -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o runtime/runtime.c runtime/driver.c` — `crt0.s` sets `sp` and calls `main`, `riscv64.ld` places everything at `RAM 0x80000000`, `driver.c` feeds `A`/`B` arrays and prints `OUT`.
* **Execute:** `rvss.c:119` `load_elf()` loads `PT_LOAD` segments into 8 MB RAM (`RAM_BASE 0x80000000:30`), `rvss.c:158` `load_syms()` finds `tohost`, `rvss.c:247` `step()` fetches `I = load(pc,4):257`, decodes (`op=I&0x7F:281`), and executes — normal ops in `rvss.c:299` or custom `case 0x0B:516` which calls `ai_vadd:79` etc. After each instruction `do_tohost():212` checks if the program wants to print or exit.

**Example:** `build/demo1.elf` runs with `./rvss build/demo1.elf` and prints `OUT = [3.0 4.0 9.0 ...]` (`setup.md:72`).

---

## How the 7 stages connect — one line traced through all 7 stages (`demos/demo1.aiir:9`)

We will follow **one single line** through the whole factory so you can see what each station does. The line is:

```
%2 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
```

In plain English: "Add two lists of 8 numbers (`%0` is input A, `%1` is input B) and store the 8 answers in a new list called `%2`." Think of `%0 = [1,2,3,4,5,6,7,8]` and `%1 = [2,2,2,2,2,2,2,2]`, so `%2` should become `[3,4,5,6,7,8,9,10]`.

---

**1. Lexical — "Split into words"**

Like a teacher cutting a sentence into word-cards. The compiler does not understand the whole line yet. It just scans left to right (`ai-compiler.c:58` `temp_of()` looks for `%`, `ai-compiler.c:70` `parse_dims()` looks for `tensor<`, `ai-compiler.c:53` already removed `;` comments and spaces).

It produces separate pieces: `%2` (the new variable), `=` (assignment), `"ai.add"` (which operation), `%0` (first input), `%1` (second input), `tensor<8xf32>` (type = "8 floats"). If it cannot find a `%` or a `(`, it does not go further — that is the first error check.

*Beginner check:* If you wrote `%2 = ai.add %0 %1` (missing quotes and brackets), Stage 1 would still split it, but Stage 2 would reject it.

**2. Syntax — "Does the grammar match?"**

Now the compiler checks the order of those word-cards, like checking `Subject-Verb-Object`. The rule it expects (`ai-compiler.c:263`) is:

```
%result = "ai.name"(%inputA [, %inputB]) : (input_types) -> output_type
```

Our line matches perfectly: `%2` before `=`, then `"ai.add"`, then `(%0, %1)` in brackets, then `:`, then `(tensor<8xf32>, tensor<8xf32>)`, then `->`, then `tensor<8xf32>`. The parser at `ai-compiler.c:272` also verifies the `(` exists, otherwise it calls `die("missing operand list")`. If you forgot `->`, it would stop here and tell you the syntax is wrong — even though the words were correct.

**3. Semantic — "Does it make sense?"**

Grammar is not enough. "The rock eats ice-cream" has perfect grammar but wrong meaning. Here the compiler asks: Are the numbers allowed? Do the variables exist?

* It calls `temp_of():63` to check each `%number` is `0..63` (`MAX_T:29`). `%2`, `%0`, `%1` all pass. `%99` would fail.
* It calls `parse_dims()` and gets `n = 8` from `tensor<8xf32>`. Then `hw_elementwise():122` checks `n > 32?` No, 8 is fine. `sw_elementwise():93` checks `n > 16?` No. If you wrote `tensor<100xf32>`, it would stop with `"tensor > 16 elements (demo limit)"` — hardware cannot hold that many.
* It makes sure a final `ai.return` exists later (`ai-compiler.c:324`), so the program actually returns something.

Our line passes all meaning checks: 8 is a small, supported size, and `%0`/`%1` are the two inputs that `demos/demo1.aiir:8` declares.

**4. IR — "Remember it in a simple private notebook"**

Instead of keeping the complicated text, the compiler saves a very simple note in its memory: `src[][]:31`. It remembers: "To compute `%2`, I need to add `%0` and `%1`, each has 8 floats, result goes to slot for `%2`."

Where does `%2` live? There are no real CPU registers for tensors. The compiler gives each temp a fixed place on the stack: `tensor_slot(2):66` = `sp - 16 - 64*(2-2)` = `sp - 16`. So `%2` means "64 bytes (16 floats, but we use 8) at `sp-16`". `%0` and `%1` are special: they are not on the stack, they are the function arguments `a0` (pointer to A) and `a1` (pointer to B) (`emit_src():84`). This stack map is shown in `architecture.md:333`.

*In your head:* `%0` = `a0` (outside), `%1` = `a1` (outside), `%2` = `sp-16` (inside, scratch paper).

**5. Optimization — "Choose the fastest way to do the same job"**

Same math, two roads. The compiler looks at the flag you gave it: `-O1` (fast, use AI hardware) or `-O0` (slow, use only normal instructions) — `ai-compiler.c:33` `emit_hw`.

* If you compiled with `-O1` (`emit_hw == 1`), it picks `hw_elementwise():121` — "Let the AI unit do all 8 adds at once."
* If you compiled with `-O0` (`emit_hw == 0`), it picks `sw_elementwise():92` — "Do 8 adds one by one in a loop with `flw`/`fadd.s`/`fsw`."

Both give the exact same numbers (`architecture.md:285`). Our line would take either road; the demo uses `-O1`.

**6. Code Generation — "Write real RISC-V instructions"**

Now it writes the output file `build/demo1.kernel.s` via `emit():40`. For our line with `-O1`, `hw_elementwise():123` writes exactly 5 text lines:

```asm
li   t0, 8                # t0 = how many numbers (8) — x5
mv   t1, a0               # t1 = address of A      — x6  (emit_src():84 sees t==0, so mv from a0)
mv   t2, a1               # t2 = address of B      — x7  (t==1, so mv from a1)
addi t3, sp, -16          # t3 = address of %2     — x28 (sp-16 is tensor_slot(2))
.word 0x14730e0b           # ai.add — built by ai_enc(0,28,6,7):47 → 0x0A<<25|7<<20|6<<15|0<<12|28<<7|0x0B
```

That `.word` is not normal assembly — it is the raw 32-bit encoding of our custom instruction (`funct7=0x0A, funct3=0, opcode=0x0B` from `docs/riscv-aiss-spec.md:24`). Think of it as a secret word only our chip understands.

If it were `-O0`, `sw_elementwise():98` would instead write a ~12-line loop: `flw fa0,0(t1)` (load one float), `flw fa1,0(t2)`, `fadd.s fa2,fa0,fa1`, `fsw fa2,0(t3)`, then `addi` pointers by 4 and `bnez` back until `t0` becomes 0 — same result, many more steps.

**7. Assembly, Linking, and Execution — "Pack it, ship it, run it"**

The `.s` text alone cannot run. Three more tools finish the job (all in `Makefile:37`):

* **Assemble:** `riscv64-unknown-elf-gcc -c build/demo1.kernel.s -o build/demo1.kernel.o` turns text into machine bytes. The `.word 0x14730e0b` stays exactly as `0x14730e0b` in the object file.
* **Link:** `riscv64-unknown-elf-gcc -T runtime/riscv64.ld ... -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o runtime/runtime.c runtime/driver.c` packs everything together. `crt0.s` puts `sp` at the top of RAM and jumps to `main`, `riscv64.ld` says "RAM starts at `0x80000000`", `driver.c` creates the real arrays `A=[1,-2,3,-4,5,-6,7,-8...]` and `B=[2,0,0,0, 0,2,0,0...]` and calls `ai_kernel(A,B,OUT)`.
* **Execute:** `./rvss build/demo1.elf` loads the ELF with `load_elf():119` into 8 MB RAM at `0x80000000:30`, then loops `step():247` — fetch 4 bytes at `pc:257`, decode `op=I&0x7F:281`. When it sees `op == 0x0B` and `f7 == 0x0A` (`rvss.c:516`), it knows it is an AI instruction, reads `funct3 == 0` and calls `ai_vadd(dst=x28, A=x6, B=x7, n=x5):523`. That function (`rvss.c:79`) does `for i 0..7: dst[i]=A[i]+B[i]` with real `float` math and `load/store` to RAM. After each instruction `do_tohost():212` checks if the program printed — at the end `driver.c` prints `OUT = [3.0 4.0 9.0 16.0 ...]` and signals exit via the `tohost` mailbox.

So that **one line** `%2 = "ai.add"(%0,%1)` became one custom instruction in the file, one object byte, one ELF segment, and finally 8 floating-point adds inside the simulator — and you see the printed result on your terminal.

All source locations above can be opened directly (e.g., `ai-compiler.c:121` for the hardware path).
