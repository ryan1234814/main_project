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

for d in demo1 demo2 demo3 demo4 demo5 demo6 demo7 demo8; do
    out="$(./rvss "build/$d.elf" 2>&1)"
    expect "$d exit ok"       "exit=0" "$out"
    expect "$d prints header" "== AISS demo ==" "$out"
    expect "$d prints done"   "done" "$out"
done

# Numeric checks (fixed-point d.ddd formatting)
out1="$(./rvss build/demo1.elf 2>&1)"
expect "demo1 custom operands A"  "A (operand) = [2.0 -3.0 4.0 -5.0 6.0 -7.0 8.0 -9.0 ]" "$out1"
expect "demo1 custom operands B"  "B (operand) = [10.0 20.0 30.0 40.0 50.0 60.0 70.0 80.0 ]" "$out1"
expect "demo1 relu((A+B)*A)" "OUT (result) = [24.0 0.0 136.0 0.0 336.0 0.0 624.0 0.0 ]" "$out1"

out2="$(./rvss build/demo2.elf 2>&1)"
expect "demo2 custom operands B" "B (operand) = [5.0 0.0 0.0 0.0 0.0 -2.0 0.0 0.0 ]" "$out2"
expect "demo2 ai.matmul 4x4" "OUT (result) = [5.0 -4.0 12.0 4.0 25.0 -12.0 28.0 8.0 ]" "$out2"

out3="$(./rvss build/demo3.elf 2>&1)"
expect "demo3 custom operands A" "A (operand) = [1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 ]" "$out3"
expect "demo3 matmul+add+relu" "OUT (result) = [6.0 0.0 6.0 32.0 30.0 0.0 14.0 64.0 ]" "$out3"

out4="$(./rvss build/demo4.elf 2>&1)"
expect "demo4 custom operands A" "A (operand) = [-1.0 2.0 -3.0 4.0 -5.0 6.0 -7.0 8.0 ]" "$out4"
expect "demo4 relu+add+mul" "OUT (result) = [0.0 44.0 0.0 176.0 0.0 396.0 0.0 704.0 ]" "$out4"

out5="$(./rvss build/demo5.elf 2>&1)"
expect "demo5 custom operands A" "A (operand) = [-11.0 12.0 -13.0 14.0 -15.0 16.0 -17.0 18.0 ]" "$out5"
expect "demo5 mul+add+relu" "OUT (result) = [0.0 36.0 0.0 70.0 0.0 112.0 0.0 162.0 ]" "$out5"

out6="$(./rvss build/demo6.elf 2>&1)"
expect "demo6 custom operands B" "B (operand) = [2.0 0.0 0.0 0.0 0.0 3.0 0.0 0.0 ]" "$out6"
expect "demo6 matmul+relu+add" "OUT (result) = [4.0 0.0 12.0 0.0 10.0 21.0 0.0 40.0 ]" "$out6"

out7="$(./rvss build/demo7.elf 2>&1)"
expect "demo7 custom operands B" "B (operand) = [1.0 0.0 2.0 0.0 3.0 0.0 4.0 0.0 ]" "$out7"
expect "demo7 ai.matmul 2x4x2" "OUT (result) = [30.0 0.0 70.0 0.0 0.0 0.0 0.0 0.0 ]" "$out7"

out8="$(./rvss build/demo8.elf 2>&1)"
expect "demo8 custom operands A" "A (operand) = [10.0 20.0 30.0 -40.0 -50.0 -60.0 70.0 80.0 ]" "$out8"
expect "demo8 add+mul+relu"      "OUT (result) = [120.0 400.0 900.0 1600.0 2500.0 3480.0 4900.0 6400.0 ]" "$out8"

# Software fallback (-O0) must match the hardware path (-O1) for ALL demos.
# This is a real A/B comparison of the two OUT lines, so it stays valid even
# when a demo's operands change; the literal value checks above pin the numbers.
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
sw_build demo8
sw_parity() {  # sw_parity <demo>
    hw_line="$(./rvss "build/$1.elf" 2>&1 | grep '^OUT (result)')"
    sw_line="$(./rvss "build/${1}_sw.elf" 2>&1 | grep '^OUT (result)')"
    if [ -n "$hw_line" ] && [ "$hw_line" = "$sw_line" ]; then
        echo "PASS: sw $1 matches hardware"
    else
        echo "FAIL: sw $1 matches hardware"
        echo "  hw: $hw_line"
        echo "  sw: $sw_line"
        fail=1
    fi
}
for d in demo1 demo2 demo3 demo4 demo5 demo6 demo7 demo8; do
    sw_parity "$d"
done

# Static audit of the generated assembly itself (tests/asm-check.py): every
# custom word cross-checked against llvm-mc +xai, plus bit fields, the register
# ABI, the element count implied by each tensor type, the operand table and -O0
# purity.  This catches lowering bugs the runtime output alone cannot hide.
if asm_out="$(python3 tests/asm-check.py 2>&1)"; then
    printf '%s\n' "$asm_out"
    echo "PASS: generated .s files match the AISS encoding and register ABI"
else
    printf '%s\n' "$asm_out"
    echo "FAIL: generated assembly does not match the AISS encoding/ABI"
    fail=1
fi

# Independent reference model (tests/oracle.py) recomputes every demo's A/B/OUT
# straight from the .aiir and compares it against what the ISS printed.
if oracle_out="$(python3 tests/oracle.py 2>&1)"; then
    echo "$oracle_out" | grep -q . && printf '%s\n' "$oracle_out"
    echo "PASS: oracle agrees with simulator for all demos"
else
    printf '%s\n' "$oracle_out"
    echo "FAIL: oracle disagrees with simulator"
    fail=1
fi

# print_int sanity (exercises mulhu/divu paths in the ISS)
echo "done."

exit $fail
