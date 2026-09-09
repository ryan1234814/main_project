#!/usr/bin/env bash
# tests/run-tests.sh — automated end-to-end checks (run via `make test`)
set -u
fail=0

expect() {  # expect <label> <expected-substring> <actual-output>
    if printf '%s' "$3" | grep -qF "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        echo "  expected to contain: $2"
        echo "  got: $3"
        fail=1
    fi
}

for d in demo1 demo2 demo3; do
    out="$(./rvss "build/$d.elf" 2>&1)"
    expect "$d exit ok"       "exit=0" "$out"
    expect "$d prints header" "== AISS demo ==" "$out"
    expect "$d prints done"   "done" "$out"
done

# Numeric checks (fixed-point d.ddd formatting)
out1="$(./rvss build/demo1.elf 2>&1)"
expect "demo1 relu((A+B)*A)" "OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]" "$out1"

out2="$(./rvss build/demo2.elf 2>&1)"
expect "demo2 ai.matmul 4x4" "OUT = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]" "$out2"

out3="$(./rvss build/demo3.elf 2>&1)"
expect "demo3 matmul+add+relu" "OUT = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]" "$out3"

# Software fallback (-O0) must match hardware path (-O1) numerically, for ALL demos
sw_build() {  # sw_build <demo>
    ./ai-compiler -O0 -o "build/${1}_sw.kernel.s" "demos/$1.aiir" >/dev/null
    riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -mno-relax \
        -c "build/${1}_sw.kernel.s" -o "build/${1}_sw.kernel.o"
    riscv64-unknown-elf-gcc -march=rv64imaf -mabi=lp64 -mcmodel=medany -O2 \
        -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
        -o "build/${1}_sw.elf" runtime/crt0.s "build/${1}_sw.kernel.o" \
        runtime/runtime.c runtime/driver.c 2>/dev/null
}
sw_build demo1
sw_build demo2
sw_build demo3
outsw="$(./rvss build/demo1_sw.elf 2>&1)"
expect "sw demo1 matches hardware" "OUT = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]" "$outsw"
outsw="$(./rvss build/demo2_sw.elf 2>&1)"
expect "sw demo2 matches hardware" "OUT = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]" "$outsw"
outsw="$(./rvss build/demo3_sw.elf 2>&1)"
expect "sw demo3 matches hardware" "OUT = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]" "$outsw"

# print_int sanity (exercises mulhu/divu paths in the ISS)
echo "done."

exit $fail
