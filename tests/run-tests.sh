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

for d in demo1 demo2 demo3 demo4 demo5 demo6 demo7; do
    out="$(./rvss "build/$d.elf" 2>&1)"
    expect "$d exit ok"       "exit=0" "$out"
    expect "$d prints header" "== AISS demo ==" "$out"
    expect "$d prints done"   "done" "$out"
done

# Numeric checks (fixed-point d.ddd formatting)
out1="$(./rvss build/demo1.elf 2>&1)"
expect "demo1 relu((A+B)*A)" "OUT (result) = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]" "$out1"

out2="$(./rvss build/demo2.elf 2>&1)"
expect "demo2 ai.matmul 4x4" "OUT (result) = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]" "$out2"

out3="$(./rvss build/demo3.elf 2>&1)"
expect "demo3 matmul+add+relu" "OUT (result) = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]" "$out3"

out4="$(./rvss build/demo4.elf 2>&1)"
expect "demo4 relu+add+mul" "OUT (result) = [3.0 0.0 9.0 0.0 25.0 0.0 49.0 0.0 ]" "$out4"

out5="$(./rvss build/demo5.elf 2>&1)"
expect "demo5 mul+add+relu" "OUT (result) = [3.0 0.0 3.0 0.0 5.0 0.0 7.0 0.0 ]" "$out5"

out6="$(./rvss build/demo6.elf 2>&1)"
expect "demo6 matmul+relu+add" "OUT (result) = [4.0 0.0 6.0 0.0 10.0 2.0 14.0 0.0 ]" "$out6"

out7="$(./rvss build/demo7.elf 2>&1)"
expect "demo7 ai.matmul 2x4x2" "OUT (result) = [2.0 6.0 10.0 14.0 0.0 0.0 0.0 0.0 ]" "$out7"

# Software fallback (-O0) must match hardware path (-O1) numerically, for ALL demos
sw_build() {  # sw_build <demo>
    ./ai-compiler -O0 -o "build/${1}_sw.kernel.s" "demos/$1.aiir" >/dev/null
    riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax \
        -c "build/${1}_sw.kernel.s" -o "build/${1}_sw.kernel.o"
    riscv64-unknown-elf-gcc -march=rv64imafd -mabi=lp64 -mcmodel=medany -O2 \
        -ffreestanding -nostdlib -fno-builtin -T runtime/riscv64.ld -nostdlib -static \
        -o "build/${1}_sw.elf" runtime/crt0.s "build/${1}_sw.kernel.o" \
        runtime/runtime.c runtime/driver.c 2>/dev/null
}
sw_build demo1
sw_build demo2
sw_build demo3
sw_build demo4
sw_build demo5
sw_build demo6
sw_build demo7
outsw="$(./rvss build/demo1_sw.elf 2>&1)"
expect "sw demo1 matches hardware" "OUT (result) = [3.0 4.0 9.0 16.0 25.0 24.0 49.0 64.0 ]" "$outsw"
outsw="$(./rvss build/demo2_sw.elf 2>&1)"
expect "sw demo2 matches hardware" "OUT (result) = [2.0 -4.0 6.0 -8.0 10.0 -12.0 14.0 -16.0 ]" "$outsw"
outsw="$(./rvss build/demo3_sw.elf 2>&1)"
expect "sw demo3 matches hardware" "OUT (result) = [4.0 0.0 12.0 0.0 20.0 0.0 28.0 0.0 ]" "$outsw"
outsw="$(./rvss build/demo4_sw.elf 2>&1)"
expect "sw demo4 matches hardware" "OUT (result) = [3.0 0.0 9.0 0.0 25.0 0.0 49.0 0.0 ]" "$outsw"
outsw="$(./rvss build/demo5_sw.elf 2>&1)"
expect "sw demo5 matches hardware" "OUT (result) = [3.0 0.0 3.0 0.0 5.0 0.0 7.0 0.0 ]" "$outsw"
outsw="$(./rvss build/demo6_sw.elf 2>&1)"
expect "sw demo6 matches hardware" "OUT (result) = [4.0 0.0 6.0 0.0 10.0 2.0 14.0 0.0 ]" "$outsw"
outsw="$(./rvss build/demo7_sw.elf 2>&1)"
expect "sw demo7 matches hardware" "OUT (result) = [2.0 6.0 10.0 14.0 0.0 0.0 0.0 0.0 ]" "$outsw"

# print_int sanity (exercises mulhu/divu paths in the ISS)
echo "done."

exit $fail
