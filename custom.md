# custom.md — Terminal Commands (custom AI instructions, `-O1` hardware `.word` path)

## Build
```bash
make clean && make && make test
```

## Demos
```bash
./rvss build/demo1.elf
./rvss build/demo2.elf
./rvss build/demo3.elf
```

## Single operations
```bash
bash tests/unit/show.sh add4 hw
bash tests/unit/show.sh add8 hw
bash tests/unit/show.sh add16 hw
bash tests/unit/show.sh mul4 hw
bash tests/unit/show.sh mul8 hw
bash tests/unit/show.sh mul16 hw
bash tests/unit/show.sh relu4 hw
bash tests/unit/show.sh relu8 hw
bash tests/unit/show.sh relu16 hw
bash tests/unit/show.sh mm111 hw
bash tests/unit/show.sh mm222 hw
bash tests/unit/show.sh mm333 hw
bash tests/unit/show.sh mm444 hw
bash tests/unit/show.sh mm242 hw
bash tests/unit/show.sh c_addrelu_mul hw
bash tests/unit/show.sh c_mm_mm hw
```

## Run one ELF directly
```bash
./rvss build/unit/add8.hw.elf
./rvss build/unit/mm444.hw.elf
```

## See every intermediate operation (per-step operands + result)
```bash
RVSS_AI_TRACE=1 ./rvss build/demo1.elf
RVSS_AI_TRACE=1 ./rvss build/demo2.elf
RVSS_AI_TRACE=1 ./rvss build/demo3.elf
bash tests/unit/show.sh demo1 hw trace
bash tests/unit/show.sh demo3 hw trace
bash tests/unit/show.sh c_addrelu_mul hw trace
bash tests/unit/show.sh c_mm_mm hw trace
bash tests/unit/show.sh add8 hw trace
bash tests/unit/show.sh relu4 hw trace
bash tests/unit/show.sh mm222 hw trace
```

## Compile one op from source
```bash
./ai-compiler -O1 -o build/demo1.kernel.s demos/demo1.aiir
```

## Encodings (opcode 0x0B, funct7 0x0A)
```bash
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.add t3, t1, t2"
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.mul t3, t1, t2"
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.relu t3, t1, zero"
llvm-build/bin/llvm-mc -triple=riscv64 -mattr=+xai --show-encoding -assemble <<<"ai.matmul t3, t1, t2"
```

## Custom words inside the built ELF
```bash
riscv64-unknown-elf-objdump -d build/demo1.elf
riscv64-unknown-elf-objdump -d build/unit/mm444.hw.elf
```

## LLVM XAi backend (same bytes)
```bash
cat > /tmp/xai.ll <<'EOF'
declare void @llvm.riscv.ai.add()
declare void @llvm.riscv.ai.mul()
declare void @llvm.riscv.ai.relu()
declare void @llvm.riscv.ai.matmul()
define void @k() {
  call void @llvm.riscv.ai.add()
  call void @llvm.riscv.ai.mul()
  call void @llvm.riscv.ai.relu()
  call void @llvm.riscv.ai.matmul()
  ret void
}
EOF
llvm-build/bin/llc -march=riscv64 -mattr=+xai --filetype=obj /tmp/xai.ll -o /tmp/xai.o
riscv64-unknown-elf-objdump -d /tmp/xai.o
```
