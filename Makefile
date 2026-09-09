# ============================================================================
# Makefile — ai-compiler + rvss (RISC-V AI-instruction demo)
# ============================================================================
CROSS   ?= riscv64-unknown-elf-
CC       = $(CROSS)gcc
AS       = $(CROSS)as
LD       = $(CROSS)ld
OBJDUMP ?= $(CROSS)objdump

HOSTCC   = cc

BUILD    = build
RUNTIME  = runtime
DEMOS    = demo1 demo2 demo3
ALL      = ai-compiler rvss $(DEMOS:%=$(BUILD)/%.elf)

MARCH    = -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax
CFLAGS   = $(MARCH) -O2 -ffreestanding -nostdlib -fno-builtin -Wall
LDFLAGS  = -T $(RUNTIME)/riscv64.ld -nostdlib -static

.PHONY: all clean test $(DEMOS) dump-%

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
$(DEMOS): %: $(BUILD)/%.elf
	./rvss $<

dump-%: $(BUILD)/%.elf
	$(OBJDUMP) -d $< | less

test: all
	@bash tests/run-tests.sh

clean:
	rm -rf $(BUILD) ai-compiler rvss
