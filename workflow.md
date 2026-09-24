# workflow.md — Run The Whole Project, Stage By Stage (commands only)

Work from the project root: `/Users/ryangeorge/llvm`

## Stage 0 — Prerequisites
```bash
riscv64-unknown-elf-gcc --version
cc --version
python3 --version
ls llvm-build/bin/llvm-mc llvm-build/bin/llc
```

## Stage 1 — Build the compiler and the simulator
```bash
make ai-compiler rvss
```

## Stage 2 — Compile a demo all the way to an ELF (one command)
```bash
make
```

## Stage 3 — Run the built demos on the simulator
```bash
./rvss build/demo1.elf
./rvss build/demo2.elf
./rvss build/demo3.elf
```

## Stage 3b — See every intermediate operation (each AI step's operands + result)
```bash
RVSS_AI_TRACE=1 ./rvss build/demo1.elf
RVSS_AI_TRACE=1 ./rvss build/demo3.elf
bash tests/unit/show.sh demo1 hw trace
bash tests/unit/show.sh c_addrelu_mul hw trace
bash tests/unit/show.sh c_mm_mm hw trace
```

## Stage 4 — The pipeline stage by stage (manual, demo1, hardware `-O1`)
```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/demo1.kernel.s -o build/demo1.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -Wall -T runtime/riscv64.ld -nostdlib -static -o build/demo1.elf runtime/crt0.s build/demo1.kernel.o runtime/runtime.c runtime/driver.c
./rvss build/demo1.elf
```

## Stage 5 — Same demo on the software path (`-O0`, no custom word)
```bash
./ai-compiler -O0 -o build/demo1_sw.kernel.s demos/demo1.aiir
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax -c build/demo1_sw.kernel.s -o build/demo1_sw.kernel.o
riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin -Wall -T runtime/riscv64.ld -nostdlib -static -o build/demo1_sw.elf runtime/crt0.s build/demo1_sw.kernel.o runtime/runtime.c runtime/driver.c
./rvss build/demo1_sw.elf
```

## Stage 6 — Inspect the custom encodings
```bash
riscv64-unknown-elf-objdump -d build/demo1.elf
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.relu t3, t1, zero"
```

## Stage 7 — Per-operation tests (custom `hw` vs normal `sw`)
```bash
bash tests/unit/show.sh add8 hw
bash tests/unit/show.sh add8 sw
bash tests/unit/show.sh mm444 hw
bash tests/unit/show.sh c_mm_mm hw
```

## Stage 8 — Full automated test suite (demos + 32 unit checks)
```bash
make test
```

## Stage 9 — LLVM backend path produces the same bytes
```bash
cat > /tmp/xai.ll <<'EOF'
declare void @llvm.riscv.ai.add()
define void @k() {
  call void @llvm.riscv.ai.add()
  ret void
}
EOF
llvm-build/bin/llc -march=riscv64 -mattr=+xai --filetype=obj /tmp/xai.ll -o /tmp/xai.o
riscv64-unknown-elf-objdump -d /tmp/xai.o
```

## Stage 10 — Start over clean
```bash
make clean
```
