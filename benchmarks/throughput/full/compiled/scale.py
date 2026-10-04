#!/usr/bin/env python3
"""Measure FIFO producer scaling in one compiled DALO MACHINE.

The runner invokes the actual compiled MACHINE for each sample. It excludes
compilation from timing, shuffles worker counts per round, validates delivery,
and preserves every raw sample for later comparison. Producer count refers to
concurrent Bash senders, not endpoint worker-process count.
"""
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
FIELDS = ('round', 'producers', 'messages', 'payload_bytes', 'seconds', 'msgps', 'bytes', 'duplicates')
PATTERN = re.compile(r'PASS mode=fifo producers=(\d+) unique=(\d+) bytes=(\d+) duplicates=(\d+) seconds=([0-9.]+) msgps=([0-9.]+)')


def positive(value):
    """Parse a strictly positive integer CLI parameter; value is user input."""
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return result


def measure(run_script, image, producers, messages, payload_bytes, timeout):
    """Run and validate one sample; arguments specify the runner, compiled image,
    concurrent sender count, expected messages, payload size, and timeout."""
    cmd = ['bash', str(run_script), 'fifo', str(messages), str(payload_bytes), str(producers), str(image)]
    proc = subprocess.run(cmd, cwd=HERE, text=True, capture_output=True, timeout=timeout)
    match = PATTERN.search(proc.stdout)
    if proc.returncode or not match:
        raise RuntimeError(f'command={cmd!r}\nexit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}')
    count, received, byte_count, duplicates = map(int, match.groups()[:4])
    seconds, msgps = map(float, match.groups()[4:])
    if (count, received, byte_count, duplicates) != (producers, messages, messages * payload_bytes, 0):
        raise RuntimeError(f'incorrect delivery: {proc.stdout}')
    if seconds <= 0 or not math.isfinite(msgps):
        raise RuntimeError(f'invalid timing: {proc.stdout}')
    return {'producers': producers, 'messages': messages, 'payload_bytes': payload_bytes,
            'seconds': seconds, 'msgps': msgps, 'bytes': byte_count, 'duplicates': duplicates}


def main():
    """Compile once and execute randomized warmup and measurement rounds; no parameters."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--counts', default='1,2,3,4,6,8,12,16,24,32',
                        help='comma-separated producer counts, each 1..32')
    parser.add_argument('--messages', type=positive, default=512)
    parser.add_argument('--payload', type=positive, default=16)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--repetitions', type=positive, default=7)
    parser.add_argument('--timeout', type=positive, default=120)
    parser.add_argument('--seed', type=int, default=20261003)
    parser.add_argument('--output', type=Path, default=Path('fifo-scaling-raw.csv'))
    parser.add_argument('--summary', type=Path, default=Path('fifo-scaling-summary.csv'))
    args = parser.parse_args()
    try:
        counts = [int(item) for item in args.counts.split(',')]
    except ValueError:
        parser.error('invalid --counts')
    if not counts or len(set(counts)) != len(counts) or any(not 1 <= x <= 32 for x in counts):
        parser.error('counts must be unique integers in 1..32')
    if args.warmups < 0 or args.messages > 100000 or args.payload > 65536:
        parser.error('invalid warmups/messages/payload')
    image = HERE / 'dalo_full_benchmark.dalo.bash'
    project = HERE / 'benchmark.dalo'
    compiler = HERE.parents[3] / 'compiler' / 'daloc.bash'
    if not image.exists() or image.stat().st_mtime < project.stat().st_mtime:
        subprocess.run(['bash', str(compiler), str(project)], check=True, cwd=HERE)
    rng = random.Random(args.seed)
    results = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=FIELDS)
        writer.writeheader()
        for round_number in range(-args.warmups, args.repetitions):
            order = counts[:]
            rng.shuffle(order)
            for producers in order:
                label = 'warmup' if round_number < 0 else f'round {round_number + 1}'
                print(f'{label}: FIFO producers={producers}', flush=True)
                try:
                    sample = measure(HERE / 'run.sh', image, producers, args.messages, args.payload, args.timeout)
                except (RuntimeError, subprocess.TimeoutExpired) as exc:
                    print(f'FAIL: {exc}', file=sys.stderr)
                    return 1
                if round_number >= 0:
                    row = {'round': round_number + 1, **sample}
                    writer.writerow(row)
                    output.flush()
                    results.append(row)
                    print(f'  {sample["msgps"]:.1f} msg/s ({sample["seconds"]:.4f} s)', flush=True)
    with args.summary.open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=('producers', 'samples', 'median_msgps', 'min_msgps',
                                                     'max_msgps', 'median_seconds', 'p95_seconds'))
        writer.writeheader()
        for producers in sorted(counts):
            subset = [row for row in results if row['producers'] == producers]
            speeds = sorted(row['msgps'] for row in subset)
            times = sorted(row['seconds'] for row in subset)
            # Nearest-rank p95 is a descriptive batch statistic, not per-message tail latency.
            p95 = times[math.ceil(.95 * len(times)) - 1]
            writer.writerow(dict(producers=producers, samples=len(subset),
                                 median_msgps=round(statistics.median(speeds), 3),
                                 min_msgps=min(speeds), max_msgps=max(speeds),
                                 median_seconds=round(statistics.median(times), 6),
                                 p95_seconds=p95))
            print(f'{producers:>2} producers: median {statistics.median(speeds):>10.1f} msg/s')
    print(f'PASS raw={args.output} summary={args.summary}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
