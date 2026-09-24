# normal.md — Terminal Commands (normal RV64IMAFD, `-O0` software path)

## Build
```bash
make clean && make && make test
```

## Demos
```bash
./rvss build/demo1_sw.elf
./rvss build/demo2_sw.elf
./rvss build/demo3_sw.elf
```

## Single operations
```bash
bash tests/unit/show.sh add4 sw
bash tests/unit/show.sh add8 sw
bash tests/unit/show.sh add16 sw
bash tests/unit/show.sh mul4 sw
bash tests/unit/show.sh mul8 sw
bash tests/unit/show.sh mul16 sw
bash tests/unit/show.sh relu4 sw
bash tests/unit/show.sh relu8 sw
bash tests/unit/show.sh relu16 sw
bash tests/unit/show.sh mm111 sw
bash tests/unit/show.sh mm222 sw
bash tests/unit/show.sh mm333 sw
bash tests/unit/show.sh mm444 sw
bash tests/unit/show.sh mm242 sw
bash tests/unit/show.sh c_addrelu_mul sw
bash tests/unit/show.sh c_mm_mm sw
```

## Run one ELF directly
```bash
./rvss build/unit/add8.sw.elf
./rvss build/unit/mm444.sw.elf
```

## Intermediate operations per step (hardware -O1 trace; the -O0 path has no custom words to trace)
```bash
RVSS_AI_TRACE=1 ./rvss build/demo1.elf
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
./ai-compiler -O0 -o build/demo1_sw.kernel.s demos/demo1.aiir
```

## Inspect the instructions
```bash
riscv64-unknown-elf-objdump -d build/unit/add8.sw.elf
riscv64-unknown-elf-objdump -d build/demo1_sw.elf
```
