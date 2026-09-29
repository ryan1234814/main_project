#!/usr/bin/env python3
"""tests/oracle.py — independent correctness check for every demo.

For each demos/<name>.aiir this script:
  1. re-reads the `; @operands:` directive (the demo's own A/B values),
  2. re-reads the ai.* op chain and tensor shapes,
  3. recomputes OUT in pure Python (a reference implementation that knows
     nothing about rvss or the compiler's lowering),
  4. runs ./rvss on the compiled ELF and compares the printed
     "A (operand)", "B (operand)" and "OUT (result)" lines.

A match therefore cross-validates the simulator, the hardware lowering and the
operand-override mechanism against an independent model.  All arithmetic is
rounded through float32 (struct pack/unpack) so it stays bit-exact with the ISS.
"""
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STOCK_A = [1, -2, 3, -4, 5, -6, 7, -8, 9, 10, 11, 12, 13, 14, 15, 16]
STOCK_B = [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2]


def f32(x):
    """Round to IEEE-754 binary32 (what the kernel actually stores)."""
    return struct.unpack('<f', struct.pack('<f', float(x)))[0]


def fmt(v):
    """Replicate runtime/runtime.c print_float() bit for bit.

    It prints the truncated whole part, then '.', then the fraction times 1000
    as an INTEGER, so 3.0 -> '3.0' while 1.5 -> '1.500' and 1.25 -> '1.250'.
    The (long) cast truncates toward zero and the negative fraction is negated,
    which is why -2.5 prints as '-2.500'.  All steps stay in float32, because
    that is where the C arithmetic happens.
    """
    x = f32(v)
    whole = int(x)                                   # C (long) cast: toward 0
    frac = int(f32(f32(x - whole) * 1000.0))
    if frac < 0:
        frac = -frac
    return '%d.%d' % (whole, frac)


def dims_of(tensor_txt):
    """'4x2xf32' -> [4, 2]; '8xf32' -> [8]; 'f32' -> [] (element type dropped)."""
    parts = tensor_txt.split('x')
    return [int(p) for p in parts[:-1] if p.isdigit()]


def numel(dims):
    n = 1
    for d in dims:
        n *= d
    return n


def is_scalar(dims):
    """A bare element type ('f32', 'i32') parses to no dimensions."""
    return not dims


def parse(path):
    """Return (operands, ops, shapes, ret_temp) for one .aiir file."""
    operands, ops, shapes, ret_temp = None, [], {}, None
    with open(path) as fh:
        for raw in fh:
            m = re.match(r'\s*;\s*@operands:\s*0x[0-9a-fA-F]+((?:\s+-?[\d.]+)+)', raw)
            if m:
                operands = [float(t) for t in m.group(1).split()]
                continue

            m = re.match(r'\s*ai\.func\s+@\w+\((.*)\)\s*->\s*(\S+)', raw)
            if m:
                for i, txt in enumerate(re.findall(r'tensor<([^>]*)>', m.group(1))):
                    shapes[i] = dims_of(txt)
                continue

            m = re.match(r'\s*%(\d+)\s*=\s*"([a-z.]+)"\(([^)]*)\)\s*:\s*\(([^)]*)\)'
                         r'\s*->\s*tensor<([^>]*)>', raw)
            if m:
                dst = int(m.group(1))
                op = m.group(2)
                args = [int(x) for x in re.findall(r'%(\d+)', m.group(3))]
                ins = [dims_of(t) for t in re.findall(r'tensor<([^>]*)>', m.group(4))]
                out = dims_of(m.group(5))
                for i, d in zip(args, ins):
                    shapes.setdefault(i, d)
                shapes[dst] = out
                ops.append((dst, op, args, out))
                continue

            m = re.match(r'\s*ai\.return\s+%(\d+)', raw)
            if m:
                ret_temp = int(m.group(1))
    return operands, ops, shapes, ret_temp


def evaluate(operands, ops, shapes):
    a = [f32(v) for v in STOCK_A]
    b = [f32(v) for v in STOCK_B]
    for i, v in enumerate((operands or [])[:32]):
        (a if i < 16 else b)[i if i < 16 else i - 16] = f32(v)

    t = {0: a, 1: b}
    for dst, op, args, out_dims in ops:
        # How many floats the kernel reads from each operand: an elementwise op
        # is sized by its result, a matmul by its own operand tiles (M*K, K*N).
        if op == 'ai.matmul':
            m_dim, n_dim = out_dims
            k_dim = int(numel(shapes.get(args[0], [1])) // (m_dim or 1))
            read_n = [m_dim * k_dim, k_dim * n_dim]
        else:
            if is_scalar(out_dims):                    # scalar result: use operand size
                out_dims = [int(numel(shapes.get(args[0], [1])) or 1)]
            read_n = [int(min(numel(out_dims), 16))] * len(args)
        reads = []
        for i, want in zip(args, read_n):
            v = list(t[i])
            v += [0.0] * (want - len(v))       # slots never written read back as 0
            reads.append(v[:want])

        if op in ('ai.add', 'ai.mul'):
            x, y = reads[0], reads[1]
            r = [f32(p + q) if op == 'ai.add' else f32(p * q) for p, q in zip(x, y)]
        elif op == 'ai.relu':
            r = [f32(x) if x > 0 else 0.0 for x in reads[0]]
        elif op == 'ai.matmul':
            x, y = reads[0], reads[1]
            r = []
            for i in range(m_dim):
                for j in range(n_dim):
                    acc = 0.0
                    for k in range(k_dim):
                        acc = f32(acc + f32(x[i * k_dim + k] * y[k * n_dim + j]))
                    r.append(acc)
        else:
            raise SystemExit('oracle: unhandled op %s' % op)
        t[dst] = r
    return a, b, t


def expected_vectors(operands, ops, shapes, ret_temp):
    """The three bracketed value lists driver.c prints, oracle-computed."""
    a, b, t = evaluate(operands, ops, shapes)
    ret_len = numel(shapes[ret_temp]) if ret_temp in shapes else 8
    out = t[ret_temp][:max(ret_len, 1)] if ret_temp in t else a[:8]
    out = list(out) + [0.0] * 16

    def vec(vs):
        return '[' + ' '.join(fmt(v) for v in vs[:8]) + ' ]'

    return vec(a), vec(b), vec(out)


def expected_lines(operands, ops, shapes, ret_temp):
    """Same values, with the driver's 'X (operand) = ' labels prepended."""
    va, vb, vout = expected_vectors(operands, ops, shapes, ret_temp)
    return ('A (operand) = ' + va, 'B (operand) = ' + vb, 'OUT (result) = ' + vout)


def run_case(name):
    operands, ops, shapes, ret_temp = parse(os.path.join(ROOT, 'demos', name + '.aiir'))
    _, _, t = evaluate(operands, ops, shapes)
    ret_len = numel(shapes[ret_temp]) if ret_temp in shapes else 8
    exp_a, exp_b, exp_out = expected_vectors(operands, ops, shapes, ret_temp)

    res = subprocess.run([os.path.join(ROOT, 'rvss'),
                          os.path.join(ROOT, 'build', name + '.elf')],
                         capture_output=True, text=True)
    got = {}
    for tag, key in (('A (operand) = ', 'a'), ('B (operand) = ', 'b'),
                     ('OUT (result) = ', 'out')):
        m = re.search(re.escape(tag) + r'(\[[^\]]*\])', res.stdout)
        got[key] = m.group(1) if m else '<missing>'

    problems = []
    for key, exp in (('a', exp_a), ('b', exp_b), ('out', exp_out)):
        if got[key] != exp:
            problems.append('%s: oracle=%s simulator=%s' % (key.upper(), exp, got[key]))
    if 'exit=0' not in res.stderr:
        problems.append('simulator did not exit cleanly')
    problems += check_full_tensor(name, t, ret_temp, ret_len)
    return problems


def check_full_tensor(name, t, ret_temp, ret_len):
    """The driver only prints the first 8 lanes, which lets a kernel that is
    wrong beyond lane 8 pass every other check.  The -O1 trace prints the whole
    destination vector of every AI op, so compare the final one against the
    oracle's full result element by element.
    """
    env = dict(os.environ, RVSS_AI_TRACE='1')
    res = subprocess.run([os.path.join(ROOT, 'rvss'),
                          os.path.join(ROOT, 'build', name + '.elf')],
                         capture_output=True, text=True, env=env)
    dsts = re.findall(r'dst:\s*\[([^\]]*)\]', res.stdout)
    if not dsts:
        return ['no AI trace to verify the unprinted lanes of %s' % name]
    want = t[ret_temp][:ret_len] if ret_temp in t else []
    if not want:
        return []
    got = [f32(float(x)) for x in dsts[-1].split()]
    problems = []
    if len(got) != len(want):
        problems.append('final op wrote %d lanes but the result tensor has %d'
                        % (len(got), len(want)))
    for i, (g, w) in enumerate(zip(got, want)):
        if g != f32(w):
            problems.append('lane %d of the full result: oracle=%s simulator=%s'
                            % (i, fmt(w), fmt(g)))
    return problems


def main():
    args = sys.argv[1:]

    # --expect <demo>: print the A/B/OUT lines the oracle predicts, without
    # touching the simulator.  tests/run-tests.sh uses it to pin the exact
    # output of a demo whose operands may have been changed dynamically.
    if args[:1] == ['--expect']:
        if len(args) != 2:
            sys.exit('usage: oracle.py --expect <demo>')
        operands, ops, shapes, ret_temp = parse(
            os.path.join(ROOT, 'demos', args[1] + '.aiir'))
        for line in expected_lines(operands, ops, shapes, ret_temp):
            print(line)
        return 0

    # Optional list of demos to check (default: everything in demos/).
    selected = args or sorted(f[:-len('.aiir')]
                              for f in os.listdir(os.path.join(ROOT, 'demos'))
                              if f.endswith('.aiir'))
    bad = 0
    for name in selected:
        if not os.path.exists(os.path.join(ROOT, 'demos', name + '.aiir')):
            sys.exit('oracle: no such demo: %s' % name)
        try:
            problems = run_case(name)
        except Exception as exc:                       # noqa: BLE001 - report, keep going
            problems = ['oracle error: %r' % exc]
        if problems:
            bad += 1
            print('FAIL: %s oracle vs simulator' % name)
            for p in problems:
                print('   ', p)
        else:
            print('PASS: %s oracle vs simulator' % name)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
