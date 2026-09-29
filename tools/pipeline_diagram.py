#!/usr/bin/env python3
"""tools/pipeline_diagram.py — 5-stage pipeline diagrams for the demos.

For one demos/<name>.aiir this reads its AI operation chain (the "input
operations": ai.add / ai.mul / ai.relu / ai.matmul, in program order), models
each AI macro-op as one instruction flowing through a classic in-order
5-stage pipeline

        IF  ->  ID  ->  EX  ->  MEM ->  WB
      fetch   decode  execute  memory writeback

inserts pipeline bubbles for read-after-write (RAW) data hazards, and writes a
space-time diagram PNG (cycles on X, instructions on Y, colour = pipeline stage,
hatched cells = stalls).

Scheduling model (documented, deliberately simple and deterministic):
  * In-order, single-issue: one instruction enters IF per cycle and stages keep
    that order (a later op can never pass an earlier one).
  * One instruction per stage per cycle (structural hazard on the AI unit).
  * RAW hazard, NO forwarding: an AI op writes its result to a stack slot in
    MEM/WB and a dependent op re-reads that slot from memory, so a consumer may
    not enter EX until its producer has finished WB (EX >= producer_WB + 1).
    This matches how the compiler lowers the tensor chain in ai-compiler.c.

Usage:
    python3 tools/pipeline_diagram.py demo1
    python3 tools/pipeline_diagram.py demo1 -o build/demo1_pipeline.png
"""
import argparse
import os
import re
import sys

# Point matplotlib's cache at a guaranteed-writable dir before import so the tool
# never warns (or fails) on machines with a read-only ~/.matplotlib.
os.environ.setdefault('MPLCONFIGDIR',
                      os.path.join(os.environ.get('TMPDIR', '/tmp'), 'aiir-mpl-cache'))

import matplotlib
matplotlib.use('Agg')                      # headless: never needs a display
import matplotlib.pyplot as plt            # noqa: E402
from matplotlib.patches import Rectangle   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

STAGES = ['IF', 'ID', 'EX', 'MEM', 'WB']
STAGE_COLOR = {          # soft textbook pastels, black bold text on top
    'IF':  '#FAD7A0',    # peach
    'ID':  '#C8E6C9',    # light green
    'EX':  '#BBDEFB',    # light blue
    'MEM': '#F8C9C9',    # light pink
    'WB':  '#E1BEE7',    # light lavender
}
STALL_COLOR = '#E2E2E2'  # pipeline bubble (data-hazard stall)
INPUT_TEMPS = (0, 1)    # %0 = A, %1 = B : available before the pipeline starts


def parse_ops(path):
    """Return the ordered AI ops: [{dst, op, srcs}, ...] straight from the .aiir."""
    ops = []
    with open(path) as fh:
        for raw in fh:
            m = re.match(r'\s*%(\d+)\s*=\s*"ai\.(\w+)"\(([^)]*)\)', raw)
            if not m:
                continue
            dst = int(m.group(1))
            op = m.group(2)
            srcs = [int(t) for t in re.findall(r'%(\d+)', m.group(3))]
            ops.append({'dst': dst, 'op': op, 'srcs': srcs})
    if not ops:
        raise SystemExit('pipeline: no ai.* operations found in %s' % path)
    return ops


def schedule(ops):
    """Assign an entry cycle to every stage of every op, in program order.

    Single-occupancy, in-order: each register (stage) holds one op per cycle, so
    op i enters a stage only once op i-1 has vacated it. A RAW hazard (op i reads
    an earlier op's result, which lives in a stack slot with no forwarding) holds
    op i in ID until the producer has finished WB; that stall then cascades back
    so op i also waits in IF. Returns (cycles, producer), cycles[i] = {stage: c}.
    """
    producer = {o['dst']: i for i, o in enumerate(ops)}
    cycles = []
    for i, o in enumerate(ops):
        deps = sorted({producer[s] for s in o['srcs']
                       if s in producer and producer[s] < i})
        prev = cycles[i - 1] if i else None
        e = {}
        e['IF'] = 0 if prev is None else max(prev['IF'] + 1, prev['ID'])
        e['ID'] = max(e['IF'] + 1, prev['EX'] if prev else e['IF'] + 1)
        ex = e['ID'] + 1
        for p in deps:                       # no forwarding: after producer WB
            ex = max(ex, cycles[p]['WB'] + 1)
        if prev:
            ex = max(ex, prev['MEM'])        # EX frees when i-1 moves to MEM
        e['EX'] = ex
        e['MEM'] = max(e['EX'] + 1, prev['WB'] if prev else e['EX'] + 1)
        e['WB'] = max(e['MEM'] + 1, prev['WB'] + 1 if prev else e['MEM'] + 1)
        cycles.append(e)
    return cycles, producer


def validate(cycles):
    """Assert the schedule is physically legal: one op per stage per cycle."""
    seen = {}
    for i, e in enumerate(cycles):
        order = STAGES
        for k, stg in enumerate(order):
            end = e[order[k + 1]] if k + 1 < len(order) else e[stg] + 1
            for c in range(e[stg], end):
                if (stg, c) in seen:
                    raise SystemExit('pipeline bug: op %d and op %d both in %s '
                                     'at cycle %d' % (seen[(stg, c)], i, stg, c))
                seen[(stg, c)] = i


def occupancy(cycles):
    """Expand the schedule into per-op, per-cycle stage labels.

    Returns a list (one per op) of dicts {cycle: (stage, is_stall)}; a stage that
    spans more than one cycle marks its extra cycles as stalls (pipeline bubbles
    caused by a data hazard).
    """
    grid = []
    for e in cycles:
        row = {}
        order = STAGES
        for k, stg in enumerate(order):
            start = e[stg]
            end = e[order[k + 1]] if k + 1 < len(order) else start + 1
            for c in range(start, end):
                row[c] = (stg, c != start)      # continuation cycle => stall
        grid.append(row)
    return grid


def op_label(i, o):
    return 'Instruction %d  (ai.%s)' % (i + 1, o['op'])


def render(name, ops, cycles, producer, out_path, dpi):
    """Textbook space-time diagram: an Execution-Clock waveform row on top,
    then one row per AI instruction with pastel IF/ID/EX/MEM/WB blocks staggered
    along the diagonal; data-hazard stalls appear as grey 'stall' bubbles."""
    grid = occupancy(cycles)
    nops = len(ops)
    ncols = max(c for e in cycles for c in e.values()) + 1

    fig, ax = plt.subplots(figsize=(max(8.0, 1.15 * ncols + 3.4),
                                    0.85 * nops + 2.6))

    # --- Execution Clock waveform (top band, above the instruction rows) ------
    yb, yt = nops + 0.30, nops + 0.92          # wave low / high levels
    wave = []
    for c in range(ncols):
        wave += [(c, yb), (c, yt), (c + 0.5, yt), (c + 0.5, yb), (c + 1, yb)]
    ax.plot([p[0] for p in wave], [p[1] for p in wave],
            color='black', lw=1.4, solid_joinstyle='miter')
    for c in range(ncols):                     # cycle numbers under each pulse
        ax.text(c + 0.5, nops + 0.08, '%d' % (c + 1),
                ha='center', va='bottom', fontsize=9, color='black')
    ax.text(-0.015, (yb + yt) / 2, 'Execution\nClock', transform=ax.get_yaxis_transform(),
            ha='right', va='center', fontsize=10, clip_on=False)

    # --- instruction rows -----------------------------------------------------
    for r, row in enumerate(grid):
        y = nops - 1 - r                        # first instruction on top
        for c in range(ncols):
            cell = row.get(c)
            if cell is None:
                continue
            stg, is_stall = cell
            color = STALL_COLOR if is_stall else STAGE_COLOR[stg]
            ax.add_patch(Rectangle((c + 0.05, y + 0.10), 0.90, 0.80,
                                   facecolor=color, edgecolor='none'))
            ax.text(c + 0.5, y + 0.5, 'stall' if is_stall else stg,
                    ha='center', va='center', fontsize=10.5,
                    fontweight='bold', color='black')

    ax.set_xlim(0, ncols)
    ax.set_ylim(0, nops + 1.15)
    ax.set_xticks([])
    ax.set_yticks([nops - 1 - r + 0.5 for r in range(nops)])
    ax.set_yticklabels([op_label(r, ops[r]) for r in range(nops)], fontsize=10)
    ax.tick_params(length=0)
    for s in ax.spines.values():
        s.set_visible(False)

    stalls = sum(1 for row in grid for (_, is_stall) in row.values() if is_stall)
    fig.suptitle('%s: Instruction Execution in a 5-Stage Pipeline' % name,
                 fontsize=14, fontweight='bold')
    ax.set_xlabel('%d AI instruction(s), %d cycles, %d stall cycle(s) '
                  '(in-order, stall-on-RAW)' % (nops, ncols, stalls),
                  fontsize=9, color='#555555')

    fig.tight_layout(rect=(0.02, 0, 1, 0.96))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fig.savefig(out_path, dpi=dpi)
    plt.close(fig)
    return ncols, stalls


def main():
    ap = argparse.ArgumentParser(description='Render a 5-stage pipeline diagram '
                                             'for a demo .aiir file.')
    ap.add_argument('demo', help='demo name (e.g. demo1) or a path to a .aiir')
    ap.add_argument('-o', '--out', help='output PNG (default build/<demo>_pipeline.png)')
    ap.add_argument('--dpi', type=int, default=150)
    args = ap.parse_args()

    path = args.demo if args.demo.endswith('.aiir') else \
        os.path.join(ROOT, 'demos', args.demo + '.aiir')
    if not os.path.exists(path):
        raise SystemExit('pipeline: no such .aiir: %s' % path)
    name = os.path.splitext(os.path.basename(path))[0]

    ops = parse_ops(path)
    cycles, producer = schedule(ops)
    validate(cycles)
    out_path = args.out or os.path.join(ROOT, 'build', '%s_pipeline.png' % name)
    ncols, stalls = render(name, ops, cycles, producer, out_path, args.dpi)

    print('pipeline: %s -> %s  (%d AI ops, %d cycles, %d stall cycle(s))'
          % (name, out_path, len(ops), ncols, stalls))
    return 0


if __name__ == '__main__':
    sys.exit(main())
