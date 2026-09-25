# desc.md — The Project's Code, Phase by Phase, in Plain English

> This file walks through the code in **stages (phases)**, following a program from a simple
> description all the way to a verified result. Each phase is explained in easy English. You do
> not need any background to follow it.
>
> For a map of which file is which, see `files.md`. For concepts, see `explain.md`.

---

## The one-line summary

We invented a few extra AI instructions for a normal computer chip, wrote a small compiler that
produces them, wrote a simulator that runs them, and proved the answers are exactly correct.

The code flows through these phases:

```
 1 describe  →  2 read & understand  →  3 translate  →  4 assemble & link
        →  5 run  →  6 show results  →  7 prove it's correct
```

---

## Phase 1 — Describing what we want (the input)

**What happens:** Instead of writing complicated chip code by hand, we write a tiny, readable
description of the math we want. That description is a `.aiir` file.

**In plain words:** "Here are two lists of numbers, A and B. Add them, multiply, then squash any
negatives to zero, and give me the result." That is basically `demos/demo1.aiir`.

**The code involved:** no code yet — this is just the input text. The three demos in `demos/`
show simple cases (one chain, one matrix multiply, a small network layer).

**Analogy:** writing a short recipe, not cooking yet.

---

## Phase 2 — Reading and understanding the description

**What happens:** our compiler program opens the `.aiir` file and figures out what it says —
which operations to do, on how many numbers, and in what order.

**The code involved:** `ai-compiler.c`. It reads the file line by line. It recognizes each
operation name (`add`, `mul`, `relu`, `matmul`), works out the size and shape of the number
lists, and keeps track of the temporary results between steps.

**Analogy:** a translator reading the recipe and understanding each step before writing it down
in another language.

---

## Phase 3 — Translating it into chip instructions

This is the heart of the project. The compiler writes RISC-V assembly (a `.s` file), and it can
do it in **two different ways** on purpose.

**Way A — the hardware way (`-O1`):** each AI step becomes **one special instruction**. That is
the whole point of our project: we created 4 instructions the chip normally doesn't have, and we
use one of them per step. In the assembly these show up as a single coded number, like
`.word 0x14730e0b` for the add.

**Way B — the software way (`-O0`):** each AI step is done with ordinary chip instructions — a
simple loop that loads a number, does the math, stores it, and repeats. No special instructions
at all.

**The code involved:** still `ai-compiler.c`. It has one set of functions that writes the special
single-instruction form, and another set that writes the plain loop form. We keep both so we can
compare them.

**Analogy:** Way A is like pressing one "blend" button on a fancy blender. Way B is doing the
same job by hand with a spoon. Both should give you the same smoothie — and that's how we check
the fancy button works.

---

## Phase 4 — Turning instructions into a runnable program

**What happens:** the assembly text isn't runnable on its own. It has to be assembled into
machine code and linked with some small support code so the program can actually start up and
run on a chip that has **no operating system**.

**The code involved:**
- `runtime/crt0.s` — the starting point: it sets up memory for the stack and then calls `main`.
- `runtime/riscv64.ld` — a simple map that says where in memory the program should sit.
- `runtime/runtime.c` — the tools to print text/numbers and to say "I'm done," without an OS.
- `runtime/driver.c` — the `main()` that hands the input numbers to our generated code and then
  prints the answer.
- A standard cross-compiler and linker (external tools) glue all this into one file called an
  **ELF** (a runnable program image).

**Analogy:** the recipe (Phase 3) plus the kitchen, pots, and stove (the runtime) so you can
actually cook.

---

## Phase 5 — Running the program on the simulator

**What happens:** there is no real chip on the desk, so we run the program on a **simulator** — a
program that pretends to be the chip. It reads the ELF and executes it one instruction at a time.

**The code involved:** `rvss.c`. It has one big loop that keeps doing three things: **fetch** the
next instruction, **decode** what it means, **execute** it. It understands all the normal RISC-V
instructions, and it also recognizes our special AI instructions — when it sees one, it performs
the matching operation (add, multiply, relu, or matrix multiply) on the numbers in its fake
memory.

The simulator also reserves a block of memory to act as the chip's RAM and sets the starting
registers, just like a real chip would.

**Analogy:** a flight simulator. Not a real plane, but it behaves like one closely enough to fly
the whole route and check the instruments.

---

## Phase 6 — Getting the results back out

**What happens:** when our running program wants to print something or finish, it can't call the
usual system functions (there's no OS). Instead it leaves a small "note" in memory for the
simulator to pick up.

**The code involved:** `runtime/runtime.c` writes those notes, and `rvss.c` reads them — one kind
of note means "show this text/number," another means "the program is finished, stop here." This
hand-off is what lets us see `A = [...]`, `B = [...]`, and `OUT = [...]` in the terminal.

**Analogy:** passing a note to a friend who is allowed to leave the room and do the errand for
you.

---

## Phase 7 — Proving the answer is correct

**What happens:** we don't just trust that the special AI instructions work — we test them three
ways and require all three to agree exactly.

1. **Hardware vs software:** the `-O1` result must match the `-O0` result byte-for-byte.
2. **Against an independent reference:** a plain-C program computes the expected answer from
   scratch, and it must also match. This third check matters because if both of our paths shared
   the same mistake, they would agree with each other yet both be wrong — the reference catches
   that.

**The code involved:**
- `tests/run-tests.sh` runs the demos and checks the above.
- `tests/unit/` checks each operation alone and in combination, at several sizes.
- `tests/unit/ref.c` is that independent reference.
- `tests/unit/show.sh` is a friendly one-command viewer that prints a case's inputs, result, and
  generated assembly, and (optionally) every intermediate step so you can watch the numbers change.

Running `make test` does all of this and reports how many checks passed.

**Analogy:** grading a student's work against the official answer key *and* against a second
teacher, to be sure the answer is truly right.

---

## Phase 8 — Showing the same idea works in a real compiler (extra credit)

**What happens:** our own compiler (`ai-compiler.c`) is small and hand-written. To prove the idea
isn't a toy, we also teach a **real, industry-grade compiler** (LLVM) the same 4 instructions.

**The code involved:** `llvm-xai.patch`, which changes just three files inside the borrowed
`llvm-project/` LLVM source to add our instructions to its RISC-V backend. We then use LLVM's
tools (in `llvm-build/`) to confirm that this real compiler produces the **exact same instruction
codes** that our own compiler and simulator use.

**Analogy:** after proving your homemade lock works, you also prove it fits a standard, factory
door — showing it could genuinely ship.

---

## How the phases fit together (the whole story in one glance)

```
 Phase 1  describe      a simple .aiir recipe
 Phase 2  read          ai-compiler.c understands it
 Phase 3  translate     ai-compiler.c writes chip code, two ways (special vs ordinary)
 Phase 4  assemble      runtime + tools make a runnable program (ELF)
 Phase 5  run           rvss.c pretends to be the chip and executes it
 Phase 6  show          results come back to the screen
 Phase 7  prove         tests check special == ordinary == independent answer
 Phase 8  double-check  a real compiler (LLVM) produces the same instructions
```

**The single idea to remember:** the special fast AI instructions and the plain slow instructions
must always produce the exact same numbers. Everything in the code exists to build those
instructions, run them, and prove they're correct.
