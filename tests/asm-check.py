#!/usr/bin/env python3
"""tests/asm-check.py — verify the generated .s files, not just their results.

For every demo this checks the -O1 (hardware) assembly against the .aiir it was
compiled from and against the AISS spec, using llvm-mc (built with the XAi
extension) as an independent encoding oracle:

  1. op sequence   - the .word directives, in order, match the .aiir operations
  2. encoding      - every custom word equals what llvm-mc produces for that op
  3. bit fields    - opcode 0x0B, funct7 0x0A, funct3 per op, rd=t3/rs1=t1/rs2=t2
  4. register ABI  - before each op, t0 holds the tensor element count and
                     t1/t2/t3 hold addresses derived from the right operands
  5. matmul shape  - t4/t5/t6 carry M/K/N matching the declared tensor shapes
  6. .data table   - the weak demo_operands table matches the `; @operands:` line
  7. -O0 purity    - the software file contains no custom AI word at all

Exit status is non-zero if any demo fails any check.
"""
import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MC = os.path.join(ROOT, 'llvm-build', 'bin', 'llvm-mc')

FUNCT3 = {'add': 0, 'relu': 1, 'mul': 2, 'matmul': 3}
OP_BY_F3 = {v: k for k, v in FUNCT3.items()}
MNEMONIC = {  # canonical fixed-register form used by the XAi backend
    'add': 'ai.add t3, t1, t2',
    'relu': 'ai.relu t3, t1, zero',      # relu ignores rs2, so the field is 0
    'mul': 'ai.mul t3, t1, t2',
    'matmul': 'ai.matmul t3, t1, t2',
}


def f32(x):
    return struct.unpack('<f', struct.pack('<f', float(x)))[0]


def llvm_encodings():
    """Ask the patched LLVM for the byte encoding of each AI op."""
    enc = {}
    for op, txt in MNEMONIC.items():
        r = subprocess.run([MC, '-triple', 'riscv64', '-mattr=+xai', '-show-encoding'],
                           input=txt + '\n', capture_output=True, text=True)
        m = re.search(r'encoding: \[(0x[0-9a-f]{2}, *){3}0x[0-9a-f]{2}\]', r.stdout)
        if not m:
            raise SystemExit('llvm-mc did not encode %r:\n%s' % (txt, r.stdout + r.stderr))
        raw = re.findall(r'0x([0-9a-f]{2})', m.group(0))
        b = [int(x, 16) for x in raw]                       # little-endian bytes
        enc[op] = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
    return enc


def parse_aiir(path):
    """Return (operands, ops, shapes) where ops is [(dst, op, args, out_dims)]."""
    operands, ops, shapes = None, [], {}
    for raw in open(path):
        m = re.match(r'\s*;\s*@operands:\s*0x[0-9a-f]+((?:\s+-?[\d.]+)+)', raw)
        if m:
            operands = [float(t) for t in m.group(1).split()]
            continue
        m = re.match(r'\s*ai\.func\s+@\w+\((.*?)\)\s*->', raw)
        if m:
            for i, txt in enumerate(re.findall(r'tensor<([^>]*)>', m.group(1))):
                shapes[i] = [int(p) for p in txt.split('x')[:-1] if p.isdigit()]
            continue
        m = re.match(r'\s*%(\d+)\s*=\s*"ai\.(\w+)"\(([^)]*)\)\s*:\s*\(([^)]*)\)\s*->'
                     r'\s*tensor<([^>]*)>', raw)
        if m:
            dst, op, argtxt, intxt, outtxt = m.groups()
            args = [int(x) for x in re.findall(r'%(\d+)', argtxt)]
            ins = [[int(p) for p in t.split('x')[:-1] if p.isdigit()]
                   for t in re.findall(r'tensor<([^>]*)>', intxt)]
            out = [int(p) for p in outtxt.split('x')[:-1] if p.isdigit()]
            for i, d in zip(args, ins):
                shapes.setdefault(i, d)
            shapes[int(dst)] = out
            ops.append((int(dst), op, args, out))
    return operands, ops, shapes


def numel(dims):
    n = 1
    for d in dims:
        n *= d
    return n


def track_state(lines):
    """Very small abstract interpreter over li/mv/addi for the t-registers.

    Returns a list of (line_number, op, snapshot) snapshots taken at each .word.
    A snapshot maps register -> ('imm', value) | ('addr', base, offset).
    """
    state, snaps = {}, []
    for no, ln in enumerate(lines, 1):
        code = ln.split('#')[0].rstrip()
        m = re.match(r'\s*li\s+(t\d),\s*(-?\d+)', code)
        if m:
            state[m.group(1)] = ('imm', int(m.group(2)))
            continue
        m = re.match(r'\s*mv\s+(t\d),\s*(a\d|t\d|sp)', code)
        if m:
            src = m.group(2)
            if src.startswith('a'):
                state[m.group(1)] = ('addr', src, 0)     # a kernel argument pointer
            else:
                state[m.group(1)] = dict(state).get(src, ('unknown', src))
            continue
        m = re.match(r'\s*addi\s+(t\d),\s*(sp|a\d|t\d),\s*(-?\d+)', code)
        if m:
            state[m.group(1)] = ('addr', m.group(2), int(m.group(3)))
            continue
        m = re.match(r'\s*\.word\s+(0x[0-9a-f]+)\s*#\s*(.*)', ln)
        if m and int(m.group(1), 16) & 0x7f == 0x0B:      # a custom-0 AI word only
            snaps.append((no, m.group(2).strip(), int(m.group(1), 16), dict(state)))
    return snaps


def comment_issues(snaps):
    """The trailing comment on each .word is the human-facing claim about it.

    If the comment and the bits ever disagree, the assembly is misleading even
    though it may still run.  Check the mnemonic, the named registers and the
    stated length against the decoded word and the tracked t0.
    """
    out = []
    for line_no, cmt, word, state in snaps:
        op = OP_BY_F3.get((word >> 12) & 7, '?')
        rd, rs1, rs2 = (word >> 7) & 31, (word >> 15) & 31, (word >> 20) & 31
        names = {6: 't1', 7: 't2', 28: 't3', 0: 'zero'}
        listed = [names.get(rd, '?'), names.get(rs1, '?')] \
            + ([names.get(rs2, '?')] if op != 'relu' else [])
        head = re.match(r'(?:ai\.)?([a-z]+)\s*(.*)', cmt)
        if not head or head.group(1) != op:
            out.append('line %d: comment %r does not name the op the bits encode (%r)'
                       % (line_no, cmt, op))
            continue
        regs = re.findall(r'\bt\d\b|\bzero\b', head.group(2))
        if regs != listed:
            out.append('line %d: comment names %s but the bits encode %s'
                       % (line_no, regs, listed))
        m = re.search(r'(?:len|n)=(\d+)', cmt)
        if m and 't0' in state and state['t0'] != ('imm', int(m.group(1))):
            out.append('line %d: comment says len=%s but t0 holds %r'
                       % (line_no, m.group(1), state['t0'][1]))
    return out


def check_demo(name, enc):
    operands, ops, shapes = parse_aiir(os.path.join(ROOT, 'demos', name + '.aiir'))
    hw_path = os.path.join(ROOT, 'build', name + '.kernel.s')
    sw_path = os.path.join(ROOT, 'build', name + '_sw.kernel.s')
    hw = open(hw_path).read()
    problems = []

    # --- 1. operation sequence -------------------------------------------
    snaps = track_state(hw.splitlines())
    problems += comment_issues(snaps)
    got_ops = [OP_BY_F3.get(int(w) >> 12 & 7, '?') for _, _, w, _ in snaps]
    if got_ops != [op for _, op, _, _ in ops]:
        problems.append('op sequence %s != .aiir %s'
                        % (got_ops, [o[1] for o in ops]))
        return problems, len(snaps)

    for idx, ((line_no, cmt, word, state), (_, ai_op, args, out_dims)) in \
            enumerate(zip(snaps, ops), 1):
        op = ai_op
        # --- 2. encoding cross-checked against llvm-mc ---------------------
        if word != enc[op]:
            problems.append('%s: .word 0x%08x but llvm-mc says 0x%08x'
                            % (op, word, enc[op]))
        # --- 3. individual bit fields --------------------------------------
        fields = dict(opcode=word & 0x7f, rd=(word >> 7) & 31, rs1=(word >> 15) & 31,
                      rs2=(word >> 20) & 31, funct3=(word >> 12) & 7, funct7=(word >> 25) & 0x7f)
        want = dict(opcode=0x0B, funct7=0x0A, funct3=FUNCT3[op], rd=28, rs1=6,
                    rs2=0 if op == 'relu' else 7)
        for k, v in want.items():
            if fields[k] != v:
                problems.append('%s (line %d): %s=%d expected %d'
                                % (op, line_no, k, fields[k], v))
        # --- 4/5. register ABI ---------------------------------------------
        if op == 'matmul':
            m_dim, n_dim = out_dims
            k_dim = numel(shapes.get(args[0], [1])) // (m_dim or 1)
            for reg, want_v, lbl in (('t4', m_dim, 'M'), ('t5', k_dim, 'K'),
                                     ('t6', n_dim, 'N')):
                got = state.get(reg)
                if got != ('imm', want_v):
                    problems.append('matmul (line %d): %s in %s is %r, shape says %d'
                                    % (line_no, lbl, reg, got, want_v))
        else:
            want_n = numel(out_dims)
            got = state.get('t0')
            if got != ('imm', want_n):
                problems.append('%s (line %d): element count t0 is %r, tensor<%s> says %d'
                                % (op, line_no, got, 'x'.join(map(str, out_dims)), want_n))
        # operand pointers must be distinct slots unless both really are an input
        ptrs = {r: state.get(r) for r in ('t1', 't2', 't3')}
        for r, v in ptrs.items():
            if r == 't2' and op == 'relu':      # relu is unary: rs2 encodes 0, t2 unused
                continue
            if v is None:
                problems.append('%s (line %d): %s never set' % (op, line_no, r))
            elif v[0] == 'imm':
                problems.append('%s (line %d): %s holds an immediate %r, not an address'
                                % (op, line_no, r, v))
        if ptrs['t3'] and ptrs['t3'][0] == 'addr' and ptrs['t3'][1] != 'sp':
            problems.append('%s (line %d): destination t3 should be a stack slot, got %r'
                            % (op, line_no, ptrs['t3']))
        for r, arg in zip(('t1', 't2'), args):
            got = ptrs[r]
            if not got:
                continue
            base = got[1] if got[0] == 'addr' else None
            if arg in (0, 1) and base != 'a%d' % arg:
                problems.append('%s (line %d): %s should point at input a%d, got %r'
                                % (op, line_no, r, arg, got))
            elif arg >= 2 and base != 'sp':
                problems.append('%s (line %d): %s should point at temp %%d\'s stack slot,'
                                ' got %r' % (op, line_no, r, arg, got))
        # a temp must never be its own destination
        if ptrs['t1'] and ptrs['t1'] == ptrs['t3']:
            problems.append('%s (line %d): srcA and dst are the same slot' % (op, line_no))

    # --- 6. operand override table -----------------------------------------
    table = re.search(r'demo_operands:\s*\n\s*\.word\s+(0x[0-9a-f]+)\s*\n'
                      r'\s*\.word\s+(\d+)\s*\n((?:\s*\.float\s+\S+\n)*)', hw)
    if operands:
        if not table:
            problems.append('; @operands: given but no demo_operands table emitted')
        else:
            magic, cnt, body = table.group(1), int(table.group(2)), table.group(3)
            vals = [float(v) for v in re.findall(r'\.float\s+(-?[\d.eE+-]+)', body)]
            if int(magic, 16) != 0x444F5031:
                problems.append('table magic %s != 0x444F5031' % magic)
            if cnt != len(vals) or len(vals) != len(operands):
                problems.append('table count=%d, floats=%d, directive=%d'
                                % (cnt, len(vals), len(operands)))
            for i, (got, want) in enumerate(zip(vals, operands)):
                if f32(got) != f32(want):
                    problems.append('table slot %d: %r != directive %r' % (i, got, want))
            if '.weak' not in hw:
                problems.append('demo_operands is not declared .weak')
            if '.data' not in hw:
                problems.append('no .data section for demo_operands')
    elif table:
        problems.append('demo_operands table emitted without a ; @operands: directive')

    # --- 7. -O0 purity ------------------------------------------------------
    if os.path.exists(sw_path):
        sw = open(sw_path).read()
        for w in re.findall(r'\.word\s+(0x[0-9a-f]{8})', sw):
            word = int(w, 16)
            if word & 0x7f == 0x0B:
                problems.append('-O0 file contains custom AI word %s' % w)
        for op in ('ai.add', 'ai.mul', 'ai.relu', 'ai.matmul'):
            if re.search(r'^\s*%s\s' % op, sw, re.M):
                problems.append('-O0 file contains mnemonic %s' % op)
    else:
        problems.append('no -O0 build present (%s)' % os.path.basename(sw_path))
    return problems, len(snaps)


def main():
    if not os.path.exists(MC):
        print('SKIP: llvm-mc not built at %s' % MC)
        return 0
    enc = llvm_encodings()
    print('llvm-mc (+xai) reference encodings: '
          + '  '.join('%s=%s' % (k, hex(v)) for k, v in sorted(enc.items())))
    bad = 0
    demos = sorted((f[:-5] for f in os.listdir(os.path.join(ROOT, 'demos'))
                    if f.endswith('.aiir')), key=lambda s: (len(s), s))
    for name in demos:
        problems, nwords = check_demo(name, enc)
        if problems:
            bad += 1
            print('FAIL: %s (%d AI words)' % (name, nwords))
            for p in problems:
                print('      ', p)
        else:
            print('PASS: %s  %d AI words: encodings, bit fields, register ABI, '
                  'operand table and -O0 purity all check out' % (name, nwords))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
