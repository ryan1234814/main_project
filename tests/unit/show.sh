#!/usr/bin/env bash
# tests/unit/show.sh — run ONE operation and print a clean, labelled summary.
#
#   usage: bash tests/unit/show.sh <case> [hw|sw]
#
#     <case>  one of:
#               add4 add8 add16            ai.add   OUT[i]=A[i]+B[i]
#               mul4 mul8 mul16            ai.mul   OUT[i]=A[i]*B[i]
#               relu4 relu8 relu16         ai.relu  OUT[i]=max(0,A[i])
#               mm111 mm222 mm333 mm444 mm242       ai.matmul  C=A@B
#               c_addrelu_mul              chain add->relu->mul   relu(A+B)*A
#               c_mm_mm                    chain matmul->matmul   (A@B)@B
#               demo1 demo2 demo3          the three demo chains
#     hw  custom  -O1 path (single .word)            [default]
#     sw  normal  -O0 path (scalar flw/fadd.s/fsw)
#
# Build the ELFs first with:  make && bash tests/unit/run-unit.sh
# Output is a single labelled block (OPERATION / ENCODING / OPERANDS / RESULT /
# ASSEMBLY). The ASSEMBLY section prints the ai-compiler-generated .s for the
# chosen path (the custom .word for hw, the scalar RV64IMAFD loop for sw).
# Add a third word `trace` to ALSO print every intermediate AI step
# (each op's real inputs + output, in execution order), e.g.
#   bash tests/unit/show.sh c_addrelu_mul hw trace
set -u
cd "$(dirname "$0")/../.."

CASE=${1:?usage: bash tests/unit/show.sh <case> [hw|sw] [trace]}
KIND=${2:-hw}
TRACE=${3:-}

desc=""; enc=""; cnt=""; demo=0
case "$CASE" in
  add4|add8|add16)    desc="ai.add   OUT[i] = A[i] + B[i]";        enc="0x14730e0b"; cnt=${CASE#add} ;;
  mul4|mul8|mul16)    desc="ai.mul   OUT[i] = A[i] * B[i]";        enc="0x14732e0b"; cnt=${CASE#mul} ;;
  relu4|relu8|relu16) desc="ai.relu  OUT[i] = max(0, A[i])";       enc="0x14031e0b"; cnt=${CASE#relu} ;;
  mm111) desc="ai.matmul 1x1x1   C = A@B";              enc="0x14733e0b"; cnt=1  ;;
  mm222) desc="ai.matmul 2x2x2   C = A@B";              enc="0x14733e0b"; cnt=4  ;;
  mm333) desc="ai.matmul 3x3x3   C = A@B";              enc="0x14733e0b"; cnt=9  ;;
  mm444) desc="ai.matmul 4x4x4   C = A@B";              enc="0x14733e0b"; cnt=16 ;;
  mm242) desc="ai.matmul 2x4x2   C = A@B (non-square)"; enc="0x14733e0b"; cnt=4  ;;
  c_addrelu_mul) desc="chain  add -> relu -> mul   OUT = relu(A+B) * A"; enc="0x14730e0b + 0x14031e0b + 0x14732e0b"; cnt=8 ;;
  c_mm_mm)       desc="chain  matmul -> matmul     OUT = (A@B) @ B";     enc="0x14733e0b x2"; cnt=4 ;;
  demo1) demo=1; desc="demo   add -> mul -> relu   OUT = relu((A+B)*A)"; enc="0x14730e0b + 0x14732e0b + 0x14031e0b"; cnt=8 ;;
  demo2) demo=1; desc="demo   ai.matmul 4x4";                            enc="0x14733e0b"; cnt=8 ;;
  demo3) demo=1; desc="demo   matmul -> add -> relu";                    enc="0x14733e0b + 0x14730e0b + 0x14031e0b"; cnt=8 ;;
  *) echo "unknown case '$CASE'" >&2
     echo "valid: add4 add8 add16 mul4 mul8 mul16 relu4 relu8 relu16 mm111 mm222 mm333 mm444 mm242 c_addrelu_mul c_mm_mm demo1 demo2 demo3" >&2
     exit 2 ;;
esac

if [ "$demo" = 1 ]; then
  if [ "$KIND" = sw ]; then ELF="build/${CASE}_sw.elf"; SFILE="build/${CASE}_sw.kernel.s"; else ELF="build/${CASE}.elf"; SFILE="build/${CASE}.kernel.s"; fi
else
  if [ "$KIND" = sw ]; then ELF="build/unit/${CASE}.sw.elf"; SFILE="build/unit/${CASE}.sw.s"; else ELF="build/unit/${CASE}.hw.elf"; SFILE="build/unit/${CASE}.hw.s"; fi
fi
if [ "$KIND" = sw ]; then kindlbl="NORMAL   -O0  (scalar flw/fadd.s/fsw)"; else kindlbl="CUSTOM   -O1  (hardware .word)"; fi

if [ ! -f "$ELF" ]; then
  echo "ELF not found: $ELF" >&2
  echo "build it first:   make && bash tests/unit/run-unit.sh" >&2
  exit 3
fi

if [ "$TRACE" = trace ]; then raw="$(RVSS_AI_TRACE=1 ./rvss "$ELF" 2>&1)"; else raw="$(./rvss "$ELF" 2>&1)"; fi
# Pull the bracketed value lists the driver prints (both drivers share labels).
pick    () { printf '%s\n' "$raw" | awk -F'[][]' -v k="$1" 'index($0,k){print $2; exit}'; }
first_n () { awk -v n="$1" '{c=0;s="";for(i=1;i<=NF&&c<n;i++){if($i=="")continue; s=s (length(s)?" ":"") $i; c++}print s}'; }

A=$(pick "A (operand)" | first_n 99)
B=$(pick "B (operand)" | first_n 99)
O=$(pick "OUT (result)" | first_n "$cnt")
stat=$(printf '%s' "$raw" | grep -Eo 'retired [0-9]+ instructions, exit=[0-9]+' | head -1)

bar="============================================================"
printf '%s\n' "$bar"
printf ' OPERATION : %s\n' "$desc"
printf ' PATH      : %s\n' "$kindlbl"
printf ' ENCODING  : .word %s\n' "$enc"
printf ' ELF RUN   : ./rvss %s\n' "$ELF"
printf '%s\n' "$bar"
printf ' OPERAND A : [ %s ]\n' "$A"
printf ' OPERAND B : [ %s ]\n' "$B"
printf ' RESULT OUT: [ %s ]   <- first %s value(s)\n' "$O" "$cnt"
printf '%s\n' "$bar"
[ -n "$stat" ] && printf ' SIM       : %s\n' "$stat"

# Assembly-level code the compiler generated for THIS path.
if [ "$KIND" = sw ]; then along="-O0 normal RV64IMAFD (no custom word)"; else along="-O1 custom AI (.word)"; fi
printf '\n%s\n' "$bar"
printf ' ASSEMBLY  : %s   [%s]\n' "$SFILE" "$along"
printf '%s\n' "$bar"
if [ -f "$SFILE" ]; then
    cat "$SFILE"
else
    printf ' (assembly file not found: %s; build it first:  make && bash tests/unit/run-unit.sh)\n' "$SFILE"
fi

if [ "$TRACE" = trace ]; then
    steps=$(printf '%s\n' "$raw" | awk '/\[ai-trace\]/{p=1} /OUT \(result\)/{p=0} p')
    printf '\n%s\n' "$bar"
    printf ' INTERMEDIATE STEPS (each AI instruction, in execution order):\n'
    printf '%s\n' "$bar"
    if [ -n "$steps" ]; then
        printf '%s\n' "$steps"
    else
        printf ' (no custom AI .word executed: this is the NORMAL -O0 software\n'
        printf '  path, lowered to plain RV64IMAFD flw/fadd.s/fsw loops, so the\n'
        printf '  hardware AI tracer has nothing to decode. Use "hw" to trace.)\n'
    fi
fi
