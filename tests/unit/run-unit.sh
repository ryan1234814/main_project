#!/usr/bin/env bash
# ============================================================================
# tests/unit/run-unit.sh — AISS per-op + chain unit tests.
#   PHASE 1: each custom op tested ALONE (add/mul/relu N=4,8,16; matmul
#            1x1x1,2x2x2,3x3x3,4x4x4,2x4x2).  Each op runs Hardware (-O1)
#            vs Software (-O0) on rvss AND vs an independent host reference.
#   PHASE 2: two new chains (add->relu->mul, matmul->matmul), + LLVM path.
#   Encoding is checked with llvm-mc --show-encoding, objdump -d, and by
#   verifying opcode=0x0B / funct7=0x0A.
# Run:  bash tests/unit/run-unit.sh      (exit 0 == everything PASS)
# ============================================================================
set -u
cd "$(dirname "$0")/../.."            # repo root
CROSS=riscv64-unknown-elf-
MARCH="-march=rv64imafd -mabi=lp64 -mcmodel=medany -mno-relax"
CFLAGS="$MARCH -O2 -ffreestanding -nostdlib -fno-builtin"
LDF="-T runtime/riscv64.ld -nostdlib -static"
MC=./llvm-build/bin/llvm-mc
LLC=./llvm-build/bin/llc
U=build/unit
mkdir -p "$U"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
no()  { echo "FAIL: $1"; fail=$((fail+1)); }

# make sure host tools exist
[ -x ./ai-compiler ] || cc -O2 -Wall -o ai-compiler ai-compiler.c
[ -x ./rvss ]        || cc -O2 -Wall -o rvss rvss.c
cc -O2 -Wall -o "$U/ref" tests/unit/ref.c || { echo "FAIL: ref.c build"; exit 1; }

# ---- helpers --------------------------------------------------------------
gen_aiir_ew () {  # gen_aiir_ew <file> <op> <N>
    cat > "$U/$1.aiir" <<EOF
ai.func @main(%0: tensor<$3xf32>, %1: tensor<$3xf32>) -> tensor<$3xf32> {
  %2 = "$2"(%0, %1) : (tensor<$3xf32>, tensor<$3xf32>) -> tensor<$3xf32>
  ai.return %2 : tensor<$3xf32>
}
ai.entry @main
EOF
}
gen_aiir_relu () {  # unary relu
    cat > "$U/$1.aiir" <<EOF
ai.func @main(%0: tensor<$2xf32>, %1: tensor<$2xf32>) -> tensor<$2xf32> {
  %2 = "ai.relu"(%0) : (tensor<$2xf32>) -> tensor<$2xf32>
  ai.return %2 : tensor<$2xf32>
}
ai.entry @main
EOF
}
gen_aiir_mm () {  # gen_aiir_mm <file> <M> <K> <N>
    cat > "$U/$1.aiir" <<EOF
ai.func @main(%0: tensor<$2x$3xf32>, %1: tensor<$3x$4xf32>) -> tensor<$2x$4xf32> {
  %2 = "ai.matmul"(%0, %1) : (tensor<$2x$3xf32>, tensor<$3x$4xf32>) -> tensor<$2x$4xf32>
  ai.return %2 : tensor<$2x$4xf32>
}
ai.entry @main
EOF
}
norm () { tr -s ' \t\n' ' ' | sed -E 's/^ +//; s/ +$//'; }
# extract the bracketed values that follow a label on the rvss output line
bracket () { ./rvss "$1" 2>/dev/null | awk -F'[][]' -v lab="$2" 'index($0, lab){print $2}' | norm; }
out_line () { ./rvss "$1" 2>/dev/null | awk -F'[][]' 'index($0, "OUT"){print $2}' | norm; }
head_n () { awk -v n="$1" '{c=0;s="";for(i=1;i<=NF&&c<n;i++){s=s (i>1?" ":"") $i;c++}print s}'; }

# one_case <base> <check> <ref-args...>   (reads $U/<base>.aiir)
one_case () {
    local base=$1 check=$2; shift 2
    ./ai-compiler -O1 -o "$U/$base.hw.s" "$U/$base.aiir" >/dev/null 2>&1 || { no "$base compile -O1"; return; }
    ./ai-compiler -O0 -o "$U/$base.sw.s" "$U/$base.aiir" >/dev/null 2>&1 || { no "$base compile -O0"; return; }
    ${CROSS}gcc $MARCH -c "$U/$base.hw.s" -o "$U/$base.hw.o" 2>/dev/null || { no "$base asm -O1"; return; }
    ${CROSS}gcc $MARCH -c "$U/$base.sw.s" -o "$U/$base.sw.o" 2>/dev/null || { no "$base asm -O0"; return; }
    ${CROSS}gcc $CFLAGS $LDF -o "$U/$base.hw.elf" runtime/crt0.s "$U/$base.hw.o" runtime/runtime.c tests/unit/unit_driver.c 2>/dev/null || { no "$base link -O1"; return; }
    ${CROSS}gcc $CFLAGS $LDF -o "$U/$base.sw.elf" runtime/crt0.s "$U/$base.sw.o" runtime/runtime.c tests/unit/unit_driver.c 2>/dev/null || { no "$base link -O0"; return; }
    local H S R Aop Bop
    H=$(out_line "$U/$base.hw.elf" | head_n "$check")
    S=$(out_line "$U/$base.sw.elf" | head_n "$check")
    R=$("$U/ref" "$@" | norm | head_n "$check")
    # operands shown in full (they are the fixed unit_test arrays, independent of shape)
    Aop=$(bracket "$U/$base.hw.elf" "A (operand)")
    Bop=$(bracket "$U/$base.hw.elf" "B (operand)")
    if [ -z "$H" ] || [ "$H" != "$S" ] || [ "$H" != "$R" ]; then
        no "$base"; echo "   hw=[$H]"; echo "   sw=[$S]"; echo "   rf=[$R]"
    else
        ok "$base  A=[$Aop] B=[$Bop] -> OUT=[$H]  (hw==sw==ref)"
    fi
}

# ---- encoding checks ------------------------------------------------------
check_word () {  # <label> <hexword>
    local w=$(( $2 ))
    local op=$(( w & 0x7F ))
    local f7=$(( (w >> 25) & 0x7F ))
    if [ "$op" -eq 11 ] && [ "$f7" -eq 10 ]; then
        ok "enc $2 opcode=0x$(printf '%x' $op) funct7=0x$(printf '%x' $f7)"
    else
        no "enc $2 opcode=0x$(printf '%x' $op) funct7=0x$(printf '%x' $f7)"
    fi
}
mc_enc () {  # <label> <asm-line> <expected-hexword>  -> llvm-mc --show-encoding
    local bytes want got
    bytes=$(printf '%s\n' "$2" | $MC -triple=riscv64 -mattr=+xai --show-encoding 2>/dev/null \
            | grep -oE '\[0x[0-9a-f]+,0x[0-9a-f]+,0x[0-9a-f]+,0x[0-9a-f]+\]' | head -1)
    got=$(printf '%s' "$bytes" | sed -E 's/.*\[0x([0-9a-f]+),0x([0-9a-f]+),0x([0-9a-f]+),0x([0-9a-f]+)\]/\4\3\2\1/')
    want=$(printf '%s' "$3" | sed 's/^0x//')
    if [ "$got" = "$want" ]; then ok "llvm-mc $1 -> 0x$got"; else no "llvm-mc $1 got=$got want=$want"; fi
}

echo "############ PHASE 1: INDIVIDUAL OPERATIONS ############"
# ai.add  N=4,8,16 (A covers 0/-/+, B covers 0/-/+)
for N in 4 8 16; do gen_aiir_ew "add$N" ai.add $N;   one_case "add$N" $N add $N;   done
# ai.mul  N=4,8,16
for N in 4 8 16; do gen_aiir_ew "mul$N" ai.mul $N;   one_case "mul$N" $N mul $N;   done
# ai.relu N=4,8,16  (first 3 = [-2,3,-0.0] -> [0,3,0])
for N in 4 8 16; do gen_aiir_relu "relu$N" $N;        one_case "relu$N" $N relu $N;  done
# ai.matmul shapes  M K N
gen_aiir_mm mm111 1 1 1; one_case mm111 1 mm 1 1 1
gen_aiir_mm mm222 2 2 2; one_case mm222 4 mm 2 2 2
gen_aiir_mm mm333 3 3 3; one_case mm333 9 mm 3 3 3
gen_aiir_mm mm444 4 4 4; one_case mm444 16 mm 4 4 4
gen_aiir_mm mm242 2 4 2; one_case mm242 4 mm 2 4 2

echo; echo "---- Phase 1 encoding checks ----"
mc_enc ai.add    "ai.add t3, t1, t2"    0x14730e0b
mc_enc ai.relu   "ai.relu t3, t1, zero" 0x14031e0b
mc_enc ai.mul    "ai.mul t3, t1, t2"    0x14732e0b
mc_enc ai.matmul "ai.matmul t3, t1, t2" 0x14733e0b
check_word add-from-s    0x14730e0b
check_word relu-from-s    0x14031e0b
check_word mul-from-s    0x14732e0b
check_word matmul-from-s  0x14733e0b
# objdump must actually show the word inside the compiled -O1 objects
for pair in "mm444:14733e0b" "add8:14730e0b" "mul8:14732e0b" "relu8:14031e0b"; do
    b=${pair%%:*}; want=${pair##*:}
    if ${CROSS}objdump -d "$U/$b.hw.o" 2>/dev/null | grep -qi "$want"; then
        ok "objdump $b.hw.o shows $want"
    else no "objdump $b.hw.o missing $want"; fi
done

echo; echo "############ PHASE 2: COMBINED OPERATIONS ############"
# chain: add -> relu -> mul  on 8 elements  ( = relu(A+B) * A )
cat > "$U/c_addrelu_mul.aiir" <<'EOF'
ai.func @main(%0: tensor<8xf32>, %1: tensor<8xf32>) -> tensor<8xf32> {
  %2 = "ai.add"(%0, %1) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  %3 = "ai.relu"(%2) : (tensor<8xf32>) -> tensor<8xf32>
  %4 = "ai.mul"(%3, %0) : (tensor<8xf32>, tensor<8xf32>) -> tensor<8xf32>
  ai.return %4 : tensor<8xf32>
}
ai.entry @main
EOF
one_case c_addrelu_mul 8 relu_add_mul 8
# chain: matmul -> matmul (double matmul) 2x2x2   ( = (A@B)@B )
cat > "$U/c_mm_mm.aiir" <<'EOF'
ai.func @main(%0: tensor<2x2xf32>, %1: tensor<2x2xf32>) -> tensor<2x2xf32> {
  %2 = "ai.matmul"(%0, %1) : (tensor<2x2xf32>, tensor<2x2xf32>) -> tensor<2x2xf32>
  %3 = "ai.matmul"(%2, %1) : (tensor<2x2xf32>, tensor<2x2xf32>) -> tensor<2x2xf32>
  ai.return %3 : tensor<2x2xf32>
}
ai.entry @main
EOF
one_case c_mm_mm 4 mm_mm 2 2 2

echo; echo "---- Phase 2 LLVM path (llc -mattr=+xai) byte-for-byte ----"
cat > "$U/xai.ll" <<'EOF'
define void @ai_kernel(float* %a, float* %b, float* %out) {
  tail call void @llvm.riscv.ai.add()
  tail call void @llvm.riscv.ai.mul()
  tail call void @llvm.riscv.ai.relu()
  tail call void @llvm.riscv.ai.matmul()
  ret void
}
declare void @llvm.riscv.ai.add()
declare void @llvm.riscv.ai.mul()
declare void @llvm.riscv.ai.relu()
declare void @llvm.riscv.ai.matmul()
EOF
$LLC -march=riscv64 -mattr=+xai --filetype=obj -o "$U/xai.o" "$U/xai.ll" 2>/dev/null
lw=$(${CROSS}objdump -d "$U/xai.o" 2>/dev/null | grep -oE '1[0-9a-f]{7}' | sort -u | tr '\n' ' ')
for w in 14730e0b 14031e0b 14732e0b 14733e0b; do
    case "$lw" in *"$w"*) ok "llc +xai emits $w";; *) no "llc +xai missing $w";; esac
done

echo
echo "============================================================"
echo "UNIT TEST SUMMARY:  $pass PASS, $fail FAIL"
echo "============================================================"
exit $(( fail > 0 ))
