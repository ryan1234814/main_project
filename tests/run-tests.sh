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

# Numeric checks.  The expected A/B/OUT strings are NOT hardcoded here: they are
# recomputed from each demo's own `; @operands:` directive by tests/oracle.py, so
# changing a demo's inputs at any time (bash tests/set-operands.sh demo1 5 6 7)
# keeps these checks exact instead of stale.
for d in demo1 demo2 demo3 demo4 demo5 demo6 demo7 demo8; do
    out="$(./rvss "build/$d.elf" 2>&1)"
    exp="$(python3 tests/oracle.py --expect "$d")"
    expect "$d operands A" "$(printf '%s\n' "$exp" | sed -n 1p)" "$out"
    expect "$d operands B" "$(printf '%s\n' "$exp" | sed -n 2p)" "$out"
    expect "$d result OUT" "$(printf '%s\n' "$exp" | sed -n 3p)" "$out"
done

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
