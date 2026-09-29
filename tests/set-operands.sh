#!/usr/bin/env bash
# tests/set-operands.sh — dynamically change the operand inputs of any demo.
#
#   bash tests/set-operands.sh <demo> <v0> [v1 ... v31]
#   make set-demo1 OPERANDS="2 -3 4 -5 6 -7 8 -9"     # replaces A's first 8 lanes only
#
# The values are written into the `; @operands:` directive of demos/<demo>.aiir
# (the single source of truth for a demo's inputs), the demo is rebuilt, run on
# the simulator, and finally cross-checked against tests/oracle.py, which
# re-reads the SAME .aiir and recomputes A/B/OUT in pure Python.
#
# Layout rule (unchanged): slots 0..15 overwrite A, slots 16..31 overwrite B.
# Supplying fewer than 32 values leaves the remaining slots at driver.c's stock
# defaults (A = 1,-2,...,16   B = 2*Identity), so a partial override is legal.
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

demo="${1:-}"
if [ $# -ge 1 ]; then shift; fi
case "$demo" in
    demo[1-8]) ;;
    "") echo "usage: bash tests/set-operands.sh <demo1..demo8> <v0> [v1 ...]" >&2; exit 1 ;;
    *) echo "error: unknown demo '$demo' (expected demo1..demo8)" >&2; exit 1 ;;
esac

aiir="demos/$demo.aiir"
[ -f "$aiir" ] || { echo "error: $aiir not found" >&2; exit 1; }
grep -q '^; @operands:' "$aiir" || {
    echo "error: $aiir has no '; @operands:' directive to rewrite" >&2; exit 1; }
[ $# -ge 1 ] || { echo "error: no operand values given" >&2; exit 1; }

# Validate every value is a plain (optionally signed, optionally fractional)
# number so a typo fails here instead of becoming a silent 0.0.
for v in "$@"; do
    if ! printf '%s' "$v" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
        echo "error: '$v' is not a valid operand value (integers/decimals only)" >&2
        exit 1
    fi
done

echo "== $demo: previous operands =="
grep '^; @operands:' "$aiir"

python3 - "$aiir" "$@" <<'PY'
import re
import sys

path, vals = sys.argv[1], [float(v) for v in sys.argv[2:]]
if not 1 <= len(vals) <= 32:
    sys.exit("error: supply between 1 and 32 values (16 for A, 16 for B)")

# driver.c's stock operands: they win wherever the directive stays silent.
stock_a = [1, -2, 3, -4, 5, -6, 7, -8, 9, 10, 11, 12, 13, 14, 15, 16]
stock_b = [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2]
a, b = [float(v) for v in stock_a], [float(v) for v in stock_b]
for i, v in enumerate(vals):
    (a if i < 16 else b)[i if i < 16 else i - 16] = v


def num(x):
    return '%g' % x


directive = '; @operands: 0x444F5031 ' + ' '.join(num(v) for v in vals)
vec_pat = re.compile(r'([AB])\s*=\s*\[[^\]]*\]')


def rewrite(line):
    """Refresh a documented 'A = [...]' / 'B = [...]' vector inside a comment.
    Handles both layouts used in demos/: a lone ';   B = [...]' line and an
    inline '; demoN's OWN operands: A = [...]' line.  A trailing parenthetical
    such as '(row-major 4x4, B = diag(2,3,4,5))' describes the PREVIOUS values,
    so it is dropped (and reported) rather than left stale."""
    if not line.startswith(';') or line.startswith('; @operands:'):
        return line, []
    if not vec_pat.search(line):
        return line, []

    def sub(m):
        vec = a if m.group(1) == 'A' else b
        return '%s = [' % m.group(1) + ' '.join(num(v) for v in vec) + ']'

    new, notes = vec_pat.sub(sub, line), []
    tail = re.match(r'(.*\])(\s*\(.*\))\s*$', new)
    if tail:
        notes.append(tail.group(2).strip())
        new = tail.group(1)
    return new, notes


with open(path) as fh:
    lines = fh.read().split('\n')

# If the numbers are unchanged, nothing in the header can have gone stale.
prev = next((l for l in lines if l.startswith('; @operands:')), '')
prev_vals = [float(t) for t in prev.split()
             if t not in (';', '@operands:') and not t.lower().startswith('0x')]
unchanged = prev_vals == vals

out, seen, dropped, review = [], False, [], []
claim = re.compile(r'stock|diag\(|lane |directive supplies|complete effective inputs')
for line in lines:
    if line.startswith('; @operands:'):
        out.append(directive)
        seen = True
        continue
    new, notes = rewrite(line)
    out.append(new)
    for n in notes:
        dropped.append('  %s' % n)
    # Free-form prose that quotes the PREVIOUS numbers cannot be regenerated
    # safely, so it is reported for a human edit instead of being left silently
    # wrong (the A/B vector lines above are always refreshed).
    if new == line and line.startswith(';') and claim.search(line) and not unchanged:
        review.append('  %s' % line.strip())

if not seen:
    sys.exit('error: no "; @operands:" line found in %s' % path)
with open(path, 'w') as fh:
    fh.write('\n'.join(out))

print('new A = [' + ' '.join(num(v) for v in a) + ']')
print('new B = [' + ' '.join(num(v) for v in b) + ']')
if len(vals) < 32:
    stock = ['A %d..%d' % (len(vals), 15)] if len(vals) < 16 else []
    if len(vals) < 32:
        stock.append('B %d..15' % (max(0, len(vals) - 16)))
    print('note: slots %s keep driver.c stock values (partial override)' % ', '.join(stock))
if dropped and not unchanged:
    print('dropped operand annotations that described the previous values:')
    for d in dropped:
        print(d)
if review:
    print('review these header lines: they describe the PREVIOUS operands in prose')
    for r in review:
        print(r)
PY

echo "== $demo: rebuilding =="
# rvss is listed too so this works straight after `make clean`.
make "build/$demo.elf" rvss >/dev/null

echo "== $demo: running on rvss (AI trace + final OUT) =="
RVSS_AI_TRACE=1 ./rvss "build/$demo.elf"

echo "== $demo: oracle cross-check (independent Python recomputation) =="
python3 tests/oracle.py "$demo"
