#!/usr/bin/env python3
"""tools/pipeline_diagram.py — cycle-accurate 5-stage pipeline diagrams.

This is a MODEL, but an *observed* one, not a postulated schedule: it runs a
real in-order single-issue 5-stage pipeline (IF/ID/EX/MEM/WB) cycle by cycle
and draws the stage occupancy it produces.  Every parameter that drives the
pipeline is MEASURED from an actual rvss execution (RVSS_PIPELINE_LOG):

  * which AI macro-ops executed, in real order, with their pc + encoding,
  * each op's EX latency = the AI engine's real datapath work (element ops for
    a vector op, M*N*K MACs for matmul — exactly the scalar-loop iteration
    count rvss runs),
  * the front-end (IF) gap between consecutive AI ops = the scalar
    instructions rvss retired in between.

Pipeline rules (documented, deliberately textbook and deterministic):
  * In-order, single-issue; one instruction per stage per cycle.
  * IF=ID=MEM=WB=1 cycle; EX = measured `work` cycles (multi-cycle AI engine).
  * RAW hazard with NO forwarding across AI results: an AI op writes its tensor
    to memory (a stack slot) and a consumer re-reads it, so a consumer may not
    enter EX until every producer has finished WB (EX >= producer_WB + 1).
    The resulting hold in ID shows as a grey 'stall' bubble.
  * The pre-first-op setup scalar work is dropped from the timeline (it is not
    an inter-op gap); only the measured gaps BETWEEN AI ops delay the front end.

rvss retires one instruction per step and runs an AI op as an atomic scalar
loop, so this is a faithful *model* of a 5-stage AI pipeline, not a measurement
of real silicon.  It is clearly labelled as such on the figure.

Usage:
    python3 tools/pipeline_diagram.py demo1
    python3 tools/pipeline_diagram.py demo1 -o build/demo1_pipeline.png
"""
import argparse
import csv
import os
import re
import subprocess
import sys

# Point matplotlib's cache at a guaranteed-writable dir before import so the tool
# never warns (or fails) on machines with a read-only ~/.matplotlib.
os.environ.setdefault('MPLCONFIGDIR',
                      os.path.join(os.environ.get('TMPDIR', '/tmp'), 'aiir-mpl-cache'))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STAGES = ['IF', 'ID', 'EX', 'MEM', 'WB']
STAGE_COLOR = {          # soft textbook pastels, black bold text on top
    'IF':  '#FAD7A0',    # peach
    'ID':  '#C8E6C9',    # light green
    'EX':  '#BBDEFB',    # light blue
    'MEM': '#F8C9C9',    # light pink
    'WB':  '#E1BEE7',    # light lavender
}
STALL_COLOR = '#E2E2E2'  # pipeline bubble (RAW-hazard / structural stall)


def parse_aiir(path):
    """Ordered AI ops from the .aiir SSA: [{dst, op, srcs}, ...] (for RAW deps)."""
    ops = []
    with open(path) as fh:
        for raw in fh:
            m = re.match(r'\s*%(\d+)\s*=\s*"ai\.(\w+)"\(([^)]*)\)', raw)
            if not m:
                continue
            ops.append({'dst': int(m.group(1)), 'op': m.group(2),
                        'srcs': [int(t) for t in re.findall(r'%(\d+)', m.group(3))]})
    return ops


def run_rvss(name, elf_path, log_path):
    """Execute the demo under rvss; rvss writes the measured CSV log."""
    if not os.path.exists(elf_path):
        raise SystemExit('pipeline: no such ELF: %s  (build it first: make %s)'
                         % (elf_path, name))
    env = dict(os.environ, RVSS_PIPELINE_LOG=log_path)
    subprocess.run([os.path.join(ROOT, 'rvss'), elf_path],
                   env=env, check=True, capture_output=True)


def parse_log(path):
    """Read rvss's measured CSV -> ordered rows (ints) + totals. No modelling."""
    if not os.path.exists(path):
        raise SystemExit('pipeline: no measured log: %s' % path)
    rows, totals = [], {}
    with open(path) as fh:
        rdr = csv.reader(l for l in fh if not l.startswith('#'))
        next(rdr, None)
        for rec in rdr:
            if len(rec) != 8:
                continue
            rows.append({'step': int(rec[0]), 'op': rec[1], 'pc': rec[2],
                         'enc': rec[3], 'scalar_before': int(rec[4]),
                         'loads': int(rec[5]), 'stores': int(rec[6]),
                         'work': int(rec[7])})
    with open(path) as fh:
        for l in fh:
            if l.startswith('## totals:'):
                totals = {k: int(v) for k, v in
                          (p.split('=') for p in l.split(':', 1)[1].split())}
                break
    if not rows:
        raise SystemExit('pipeline: log has no AI ops: %s' % path)
    return rows, totals


def attach_deps(rows, aiir_path):
    """Join measured rows (execution order) with the .aiir SSA to find RAW deps.

    For these straight-line single-block demos the log order equals the SSA
    order; we verify the op names line up and otherwise fall back to a linear
    producer chain so the figure never silently mislabels dependencies.
    """
    deps = [set() for _ in rows]
    ssa = parse_aiir(aiir_path) if os.path.exists(aiir_path) else []
    if len(ssa) == len(rows) and all(s['op'] == r['op'].split('.')[-1]
                                     for s, r in zip(ssa, rows)):
        producer = {s['dst']: i for i, s in enumerate(ssa)}
        for i, s in enumerate(ssa):
            for src in s['srcs']:
                p = producer.get(src)
                if p is not None and p < i:
                    deps[i].add(p)
    else:  # SSA/log mismatch (loop or unrolled): conservative linear chain
        for i in range(1, len(rows)):
            deps[i].add(i - 1)
    return deps


def simulate(rows, deps):
    """Run the 5-stage pipeline cycle by cycle; return per-op stage intervals.

    Returns a list of dicts {stage: (enter_cycle, exit_cycle)} plus totals.
    Stalls EMERGE from the hazard + structural rules; nothing is postulated.
    """
    sched = []
    next_free = {s: 0 for s in STAGES}
    front = 0                                   # cycle the front end is next free
    for i, r in enumerate(rows):
        if i > 0:
            front += r['scalar_before']          # measured scalar work between AI ops
        e = {}
        e['IF'] = (max(front, next_free['IF']), 0)
        e['IF'] = (e['IF'][0], e['IF'][0] + 1)
        front = e['IF'][1]
        next_free['IF'] = e['IF'][1]
        id_e = max(e['IF'][1], next_free['ID'])
        e['ID'] = (id_e, id_e + 1)
        next_free['ID'] = e['ID'][1]
        ex_ready = e['ID'][1]
        for p in deps[i]:                        # no forwarding across tensor results
            ex_ready = max(ex_ready, sched[p]['WB'][1] + 1)
        ex_e = max(ex_ready, next_free['EX'])    # AI engine single-occupancy
        e['EX'] = (ex_e, ex_e + max(r['work'], 1))
        next_free['EX'] = e['EX'][1]
        mem_e = max(e['EX'][1], next_free['MEM'])
        e['MEM'] = (mem_e, mem_e + 1)
        next_free['MEM'] = e['MEM'][1]
        wb_e = max(e['MEM'][1], next_free['WB'])
        e['WB'] = (wb_e, wb_e + 1)
        next_free['WB'] = e['WB'][1]
        sched.append(e)
    return sched


def occupancy(sched):
    """Expand intervals into per-op {cycle: (stage_or_stall, is_stall)} cells."""
    grid = []
    for e in sched:
        row = {}
        for stg in STAGES:
            a, b = e[stg]
            for c in range(a, b):
                row[c] = (stg, False)
        # fill RAW/structural bubbles between ID end and EX start
        for c in range(e['ID'][1], e['EX'][0]):
            row[c] = ('stall', True)
        grid.append(row)
    return grid


def render(name, rows, sched, out_path, dpi):
    import matplotlib
    matplotlib.use('Agg')                      # headless: never needs a display
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    grid = occupancy(sched)
    n = len(rows)
    ncols = max(b for e in sched for (a, b) in e.values())

    fig, ax = plt.subplots(figsize=(max(9.0, 0.42 * ncols + 4.5), 0.95 * n + 2.6))

    # clock waveform + numbered cycles on top
    yb, yt = n + 0.30, n + 0.92
    wave = []
    for c in range(ncols):
        wave += [(c, yb), (c, yt), (c + 0.5, yt), (c + 0.5, yb), (c + 1, yb)]
    ax.plot([p[0] for p in wave], [p[1] for p in wave], color='black', lw=1.2)
    for c in range(ncols):
        ax.text(c + 0.5, n + 0.06, '%d' % c, ha='center', va='bottom', fontsize=7)
    ax.text(-0.015, (yb + yt) / 2, 'Cycle', transform=ax.get_yaxis_transform(),
            ha='right', va='center', fontsize=10, clip_on=False)

    for r, row in enumerate(grid):
        y = n - 1 - r
        for c in range(ncols):
            cell = row.get(c)
            if cell is None:
                continue
            stg, is_stall = cell
            color = STALL_COLOR if is_stall else STAGE_COLOR[stg]
            ax.add_patch(Rectangle((c + 0.04, y + 0.12), 0.92, 0.76,
                                   facecolor=color, edgecolor='none'))
            label = 'stall' if is_stall else stg
            # label a multi-cycle EX bar once, with its measured work width
            if stg == 'EX' and not is_stall:
                a, b = sched[r]['EX']
                if c == (a + b) // 2:
                    label = 'EX (%d)' % (b - a)
                else:
                    label = ''
            if label:
                ax.text(c + 0.5, y + 0.5, label, ha='center', va='center',
                        fontsize=9, fontweight='bold', color='black')

    ax.set_xlim(0, ncols)
    ax.set_ylim(0, n + 1.15)
    ax.set_xticks([])
    ax.set_yticks([n - 1 - r + 0.5 for r in range(n)])
    ax.set_yticklabels(['AI %s  @%s' % (rows[r]['op'], rows[r]['pc'])
                        for r in range(n)], fontsize=9, family='monospace')
    ax.tick_params(length=0)
    for s in ax.spines.values():
        s.set_visible(False)

    stalls = sum(1 for row in grid for (_, s) in row.values() if s)
    fig.suptitle('%s: 5-Stage AI Pipeline (rvss cycle-accurate model)' % name,
                 fontsize=14, fontweight='bold')
    ax.set_xlabel('%d AI op(s), %d cycles, %d stall cycle(s) | EX width = '
                  'measured datapath work; in-order, stall-on-RAW (no forwarding)'
                  % (n, ncols, stalls), fontsize=9, color='#555555')

    fig.tight_layout(rect=(0.02, 0, 1, 0.95))
    os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)
    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)
    return ncols, stalls


def main():
    ap = argparse.ArgumentParser(description='Render a cycle-accurate 5-stage '
                                             'AI pipeline diagram for a demo.')
    ap.add_argument('demo', help='demo name (e.g. demo1) or a path to a .aiir')
    ap.add_argument('-o', '--out', help='output PNG (default build/<demo>_pipeline.png)')
    ap.add_argument('--dpi', type=int, default=150)
    args = ap.parse_args()

    if args.demo.endswith('.aiir'):
        aiir = args.demo
        name = os.path.splitext(os.path.basename(aiir))[0]
    else:
        name = args.demo
        aiir = os.path.join(ROOT, 'demos', name + '.aiir')
    log_path = os.path.join(ROOT, 'build', '%s.pipeline.csv' % name)
    elf = os.path.join(ROOT, 'build', '%s.elf' % name)

    run_rvss(name, elf, log_path)
    rows, totals = parse_log(log_path)
    deps = attach_deps(rows, aiir)
    sched = simulate(rows, deps)
    out_path = args.out or os.path.join(ROOT, 'build', '%s_pipeline.png' % name)
    ncols, stalls = render(name, rows, sched, out_path, args.dpi)

    print('pipeline: %s -> %s  (%d AI ops, %d cycles, %d stall cycle(s), '
          '%d scalar insn(s) measured)'
          % (name, out_path, len(rows), ncols, stalls,
             totals.get('scalar_insns', 0)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
