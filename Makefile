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
# It also renders a 5-stage pipeline diagram to build/<demo>_pipeline.png
# (needs python3 + matplotlib; skipped with a note if matplotlib is absent).
$(DEMOS): %: $(BUILD)/%.elf
	@printf '\n>>>>>>>>>> %s: intermediate AI operations + results, then final OUT <<<<<<<<<<\n' "$@"
	@RVSS_AI_TRACE=1 ./rvss $<
	@if python3 -c 'import matplotlib' >/dev/null 2>&1; then \
	    python3 tools/pipeline_diagram.py "$@"; \
	else \
	    echo "note: pipeline diagram skipped (install with: pip3 install matplotlib)"; \
	fi

run-all: $(DEMOS)

dump-%: $(BUILD)/%.elf
	$(OBJDUMP) -d $< | less

# ---- 5-stage pipeline diagrams --------------------------------------------
# Textbook IF/ID/EX/MEM/WB space-time diagram for a demo's AI instruction chain,
# read straight from demos/<demo>.aiir (models in-order issue + RAW-hazard
# stalls). Output is build/<demo>_pipeline.png.
#   make pipeline-demo1        # one demo
#   make pipeline-all          # all demos
# `make demoN` already produces the diagram too, so this target is just a
# convenience for regenerating a picture without rebuilding/running the ELF.
PIPELINE ?= python3 tools/pipeline_diagram.py
pipeline-%:
	@$(PIPELINE) $*

pipeline-all:
	@for d in $(DEMOS); do $(PIPELINE) $$d; done

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
