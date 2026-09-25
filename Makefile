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
DEMOS    = demo1 demo2 demo3 demo4 demo5 demo6 demo7
ALL      = ai-compiler rvss $(DEMOS:%=$(BUILD)/%.elf)

# Rocket Chip's base ISA is RV64IMAFD; the AISS custom AI ops ride on top in
# the custom-0 opcode space, so they never clash with standard instructions.
MARCH    = -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax
CFLAGS   = $(MARCH) -O2 -ffreestanding -nostdlib -fno-builtin -Wall
LDFLAGS  = -T $(RUNTIME)/riscv64.ld -nostdlib -static

.PHONY: all clean test $(DEMOS) run-all dump-%

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
$(DEMOS): %: $(BUILD)/%.elf
	@printf '\n>>>>>>>>>> %s: intermediate AI operations + results, then final OUT <<<<<<<<<<\n' "$@"
	@RVSS_AI_TRACE=1 ./rvss $<

run-all: $(DEMOS)

dump-%: $(BUILD)/%.elf
	$(OBJDUMP) -d $< | less

test: all
	@bash tests/run-tests.sh
	@bash tests/unit/run-unit.sh

clean:
	rm -rf $(BUILD) ai-compiler rvss
