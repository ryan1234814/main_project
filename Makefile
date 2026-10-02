# ============================================================================
# Makefile — ai-compiler + rvss (RISC-V AI-instruction demo)
# Target ISA: Rocket Chip RV64IMAFD (RV64I + M + A + F + D unprivileged ISA)
# + the AISS custom-0 AI extension (ai.add/ai.relu/ai.mul/ai.matmul).
# ============================================================================
CROSS   ?= riscv64-unknown-elf-
CC       = $(CROSS)gcc
AS       = $(CROSS)as
LD       = $(CROSS)ld
OBJDUMP ?= $(CROSS)objdump

HOSTCC   = cc

BUILD    = build
RUNTIME  = runtime
DEMOS    = demo1 demo2 demo3 demo4 demo5 demo6 demo7 demo8
ALL      = ai-compiler rvss $(DEMOS:%=$(BUILD)/%.elf)

# Rocket Chip's base ISA is RV64IMAFD; the AISS custom AI ops ride on top in
# the custom-0 opcode space, so they never clash with standard instructions.
MARCH    = -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax
CFLAGS   = $(MARCH) -O2 -ffreestanding -nostdlib -fno-builtin -Wall
LDFLAGS  = -T $(RUNTIME)/riscv64.ld -nostdlib -static

.PHONY: all clean test $(DEMOS) run-all dump-% set-% pipeline-% pipeline-all

all: $(ALL)

# ---- host tools -----------------------------------------------------------
ai-compiler: ai-compiler.c
	$(HOSTCC) -O2 -Wall -o $@ $<

rvss: rvss.c
	$(HOSTCC) -O2 -Wall -o $@ $<

# ---- demo pipeline: .aiir -> .s -> .o -> .elf ------------------------------
define DEMO_RULES
$(BUILD)/$(1).kernel.s: demos/$(1).aiir ai-compiler | $(BUILD)
	./ai-compiler -O1 -o $$@ $$<

$(BUILD)/$(1).kernel.o: $(BUILD)/$(1).kernel.s
	$(CC) $(MARCH) -c $$< -o $$@

$(BUILD)/$(1).elf: $(BUILD)/$(1).kernel.o $(RUNTIME)/crt0.s $(RUNTIME)/runtime.c $(RUNTIME)/driver.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $$@ $(RUNTIME)/crt0.s $$< $(RUNTIME)/runtime.c $(RUNTIME)/driver.c
endef

$(foreach d,$(DEMOS),$(eval $(call DEMO_RULES,$(d))))

$(BUILD):
	mkdir -p $(BUILD)

# ---- run + inspect --------------------------------------------------------
# Running a demo ALWAYS prints each intermediate AI operation and its result
# (RVSS_AI_TRACE makes rvss decode every custom AI .word as it executes),
# followed by the final OUT. So `make demo1`/`demo2`/`demo3` show the steps.
# It also writes the MEASURED per-op execution log to build/<demo>.pipeline.csv
# (rvss instruments the real run: retired scalar insns + RAM load/store traffic).
# `make pipeline-demoN` then runs rvss again and renders the diagram from that
# measurement (needs python3 + matplotlib; --log-only works without them).
$(DEMOS): %: $(BUILD)/%.elf
	@printf '\n>>>>>>>>>> %s: intermediate AI operations + results, then final OUT <<<<<<<<<<\n' "$@"
	@RVSS_AI_TRACE=1 RVSS_PIPELINE_LOG=$(BUILD)/$@.pipeline.csv ./rvss $<

run-all: $(DEMOS)

dump-%: $(BUILD)/%.elf
	$(OBJDUMP) -d $< | less

# ---- measured execution diagrams -------------------------------------------
# No modelled figures: the tool RUNS build/<demo>.elf under rvss, which records
# the measured per-AI-op metrics (real pc/encoding, scalar instructions retired
# between AI ops, RAM load/store traffic) to build/<demo>.pipeline.csv, then
# renders build/<demo>_pipeline.png as a proportional measured space-time
# diagram.  Every number on the picture comes from that one actual execution.
#   make pipeline-demo1        # one demo
#   make pipeline-all          # all demos
PIPELINE ?= python3 tools/pipeline_diagram.py
pipeline-%: $(BUILD)/%.elf rvss
	@$(PIPELINE) $*

pipeline-all: $(DEMOS:%=pipeline-%)

# ---- dynamic operand override ---------------------------------------------
# Rewrite a demo's input values, rebuild it, run it and cross-check the result:
#   make set-demo1 OPERANDS="2 -3 4 -5 6 -7 8 -9"
#   make set-demo8 OPERANDS="1 1 1 1 1 1 1 1  2 2 2 2 2 2 2 2  3 3 3 3 3 3 3 3"
# Slots 0..15 fill A, slots 16..31 fill B; anything not supplied keeps driver.c's
# stock value.  The new values are written into demos/<demo>.aiir's own
# `; @operands:` line, so the oracle/asm audits and `make test` stay in sync.
OPERANDS ?=
set-%:
	@bash tests/set-operands.sh $* $(OPERANDS)

test: all
	@bash tests/run-tests.sh
	@bash tests/unit/run-unit.sh

clean:
	rm -rf $(BUILD) ai-compiler rvss
