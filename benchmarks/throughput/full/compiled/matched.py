#!/usr/bin/env python3
"""Measure matched DIRECT/FIFO compiled-MACHINE configurations without mislabeling producers as endpoint workers."""
import argparse
import csv
import math
import random
import re
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PASS = re.compile(r'^PASS mode=(direct|fifo) producers=(\d+) unique=(\d+) bytes=(\d+) duplicates=(\d+) seconds=([0-9.]+) msgps=([0-9.]+)$', re.M)
FIELDS = ('round', 'mode', 'producers', 'messages', 'payload_bytes', 'seconds', 'msgps', 'received_bytes', 'duplicates')


def measure(runner, mode, producers, messages, payload, timeout):
    """Execute one compiled-MACHINE run and validate it; runner is its shell path, mode is transport,
    producers is sender-process count, messages is total frames, payload is bytes/frame, timeout is seconds.
    """
    proc = subprocess.run(['bash', str(runner), mode, str(messages), str(payload), str(producers)],
                          cwd=runner.parent, capture_output=True, text=True, timeout=timeout)
    match = PASS.search(proc.stdout)
    if proc.returncode or not match:
        raise RuntimeError(f'{mode}/{producers}: exit={proc.returncode}\n{proc.stdout}\n{proc.stderr}')
    actual_mode = match.group(1)
    actual_producers, unique, byte_count, duplicates = map(int, match.groups()[1:5])
    seconds, rate = map(float, match.groups()[5:])
    if (actual_mode, actual_producers, unique, byte_count, duplicates) != (mode, producers, messages, messages * payload, 0):
        raise RuntimeError(f'Incorrect delivery: {match.group(0)}')
    if not (math.isfinite(seconds) and seconds > 0 and math.isfinite(rate) and rate > 0):
        raise RuntimeError(f'Invalid timing: {match.group(0)}')
    return dict(mode=mode, producers=producers, messages=messages, payload_bytes=payload,
                seconds=seconds, msgps=rate, received_bytes=byte_count, duplicates=duplicates)


def main():
    """Run shuffled matched measurements and write raw and median CSV files; parameters come from CLI."""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sizes', default='1,16,256,2048')
    p.add_argument('--messages', type=int, default=256)
    p.add_argument('--fifo-max-payload', type=int, default=256,
                   help='Maximum FIFO payload permitted by the compiled MACHINE (default: conservative 256 B for PIPE_BUF=512); larger sizes run DIRECT only')
    p.add_argument('--warmups', type=int, default=2)
    p.add_argument('--repetitions', type=int, default=7)
    p.add_argument('--timeout', type=int, default=180)
    p.add_argument('--seed', type=int, default=20261003)
    p.add_argument('--output', type=Path, default=Path('matched-raw.csv'))
    p.add_argument('--summary', type=Path, default=Path('matched-summary.csv'))
    args = p.parse_args()
    try:
        sizes = [int(x) for x in args.sizes.split(',')]
    except ValueError:
        p.error('Invalid --sizes')
    if not sizes or len(sizes) != len(set(sizes)) or any(x < 1 or x > 2048 for x in sizes):
        p.error('Sizes must be distinct and between 1 and 2048 bytes')
    if args.fifo_max_payload < 0 or args.fifo_max_payload > 2048:
        p.error('--fifo-max-payload must be between 0 and 2048')
    if not 1 <= args.messages <= 100000 or args.repetitions < 1 or args.warmups < 0 or args.timeout < 1:
        p.error('Invalid message, repetition, warmup or timeout count')
    runner = HERE / 'run.sh'
    project = HERE / 'benchmark.dalo'
    image = HERE / 'dalo_full_benchmark.dalo.bash'
    compiler = HERE.parents[3] / 'compiler' / 'daloc.bash'
    if not image.exists() or image.stat().st_mtime < project.stat().st_mtime:
        subprocess.run(['bash', str(compiler), str(project)], cwd=HERE, check=True)
    # DIRECT currently supports one parent-process producer. FIFO uses real 1..4 producer processes.
    # Do not send frames larger than the platform's atomic FIFO write limit.
    # The default reserves room for framing when PIPE_BUF is only 512 bytes.
    # DIRECT remains eligible for all requested payload sizes.
    configurations = [(mode, n, size) for size in sizes
                      for mode, counts in (('direct', (1,)), ('fifo', (1, 2, 3, 4)))
                      if mode == 'direct' or size <= args.fifo_max_payload
                      for n in counts]
    skipped = [size for size in sizes if size > args.fifo_max_payload]
    if skipped:
        print(f'NOTE FIFO payload sizes excluded due to atomic-frame limit: {skipped}; DIRECT still measured', flush=True)
    rng = random.Random(args.seed)
    measured = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', newline='') as out:
        writer = csv.DictWriter(out, fieldnames=FIELDS)
        writer.writeheader()
        for round_index in range(-args.warmups, args.repetitions):
            order = configurations[:]
            rng.shuffle(order)
            for mode, producers, size in order:
                label = 'warmup' if round_index < 0 else f'round={round_index + 1}'
                print(f'{label} {mode} producers={producers} bytes={size}', flush=True)
                try:
                    row = measure(runner, mode, producers, args.messages, size, args.timeout)
                except (RuntimeError, subprocess.TimeoutExpired) as exc:
                    print(f'FAIL {exc}', file=sys.stderr)
                    return 1
                if round_index >= 0:
                    row = {'round': round_index + 1, **row}
                    writer.writerow(row)
                    out.flush()
                    measured.append(row)
    with args.summary.open('w', newline='') as out:
        writer = csv.DictWriter(out, fieldnames=('mode', 'producers', 'payload_bytes', 'samples', 'median_msgps', 'median_seconds', 'min_msgps', 'max_msgps'))
        writer.writeheader()
        for mode, producers, size in configurations:
            rows = [r for r in measured if (r['mode'], r['producers'], r['payload_bytes']) == (mode, producers, size)]
            writer.writerow(dict(mode=mode, producers=producers, payload_bytes=size, samples=len(rows),
                                 median_msgps=round(statistics.median(r['msgps'] for r in rows), 3),
                                 median_seconds=round(statistics.median(r['seconds'] for r in rows), 6),
                                 min_msgps=min(r['msgps'] for r in rows), max_msgps=max(r['msgps'] for r in rows)))
    print(f'PASS configurations={len(configurations)} measured={len(measured)} raw={args.output} summary={args.summary}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
