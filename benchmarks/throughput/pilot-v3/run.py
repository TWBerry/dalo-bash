#!/usr/bin/env python3
"""Run bounded FIFO pilot measurements with explicit setup/warmup separation.

This is a measurement-harness milestone, not a DIRECT/FIFO comparison.
Each invocation still launches a new Bash process and reinitializes the MACHINE.
"""
import argparse
import csv
import math
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

METRIC = re.compile(r"^METRIC: seconds=([0-9.]+) bytes=(\d+) messages=(\d+) MiBps=([0-9.]+) msgps=([0-9.]+)$", re.M)
PASS = re.compile(r"^PASS: fifo pilot \+ scenario=(normal|retry) unique=(\d+) bytes=(\d+) duplicates=(\d+)$", re.M)


def execute(command, timeout, env=None):
    """Execute command with a hard deadline; command is the argument vector, timeout is seconds, env overrides the environment."""
    start = time.monotonic()
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout, env=env, check=False)
    return result, time.monotonic() - start


def percentile(values, fraction):
    """Return nearest-rank percentile; values are observed measurements and fraction is in [0,1]."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def main():
    """Prepare compiled FIFO cases, run warmups and repetitions, and write raw/summary CSV; CLI supplies all settings."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path, help='DALO repository root')
    parser.add_argument('output', type=Path, help='raw CSV output path')
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--sizes', type=int, nargs='+', default=[1, 16, 256])
    parser.add_argument('--timeout', type=int, default=90)
    args = parser.parse_args()
    if args.repetitions < 3 or args.warmups < 0 or args.timeout < 1 or any(s not in (1, 16, 256) for s in args.sizes):
        parser.error('repetitions >= 3, warmups >= 0, timeout >= 1; supported sizes: 1,16,256')
    root = args.root.resolve()
    pilot = root / 'benchmarks/throughput/pilot'
    here = Path(__file__).resolve().parent
    args.output.parent.mkdir(parents=True, exist_ok=True)
    summary_path = args.output.with_name(args.output.stem + '-summary.csv')
    raw_fields = ['mode', 'scenario', 'payload_bytes', 'repetition', 'warmup', 'clients', 'messages',
                  'transfer_seconds', 'mib_per_second', 'messages_per_second', 'run_wall_seconds', 'status']
    summary_fields = ['mode', 'scenario', 'payload_bytes', 'repetitions', 'median_seconds',
                      'p95_seconds', 'p99_seconds', 'median_messages_per_second', 'median_mib_per_second',
                      'min_seconds', 'max_seconds', 'compile_wall_seconds']
    raw_rows, summaries = [], []
    with tempfile.TemporaryDirectory(prefix='dalo-pilot-v3-') as temporary:
        tmp = Path(temporary)
        for size in args.sizes:
            case = tmp / f'size-{size}'
            result, _ = execute([sys.executable, str(pilot / 'build.py'), str(pilot), str(case), str(size)], args.timeout)
            if result.returncode:
                raise RuntimeError(f'case generation failed for {size}: {result.stdout}')
            result, _ = execute([sys.executable, str(here / 'prepare.py'), str(case / 'test.sh')], args.timeout)
            if result.returncode:
                raise RuntimeError(f'case preparation failed for {size}: {result.stdout}')
            result, _ = execute(['bash', '-n', str(case / 'test.sh')], args.timeout)
            if result.returncode:
                raise RuntimeError(f'generated Bash syntax failed for {size}: {result.stdout}')
            print(f'COMPILE size={size}', flush=True)
            result, compile_wall = execute(['bash', str(root / 'compiler/daloc.bash'), str(case / 'probe.dalo')], args.timeout)
            compiled = case / 'compiled_ack_topology.dalo.bash'
            if result.returncode or not compiled.is_file():
                raise RuntimeError(f'compile failed for {size}: {result.stdout}')
            for scenario in ('normal', 'retry'):
                times, rates, bandwidths = [], [], []
                for index in range(-args.warmups, args.repetitions):
                    warmup = index < 0
                    label = f'WARMUP {index + args.warmups + 1}' if warmup else f'REP {index + 1}'
                    print(f'RUN size={size} scenario={scenario} {label}', flush=True)
                    import os
                    env = os.environ.copy()
                    env['DALO_PILOT_V2_COMPILED'] = str(compiled)
                    try:
                        result, wall = execute(['bash', str(case / 'test.sh'), str(root), scenario], args.timeout, env)
                    except subprocess.TimeoutExpired as exc:
                        raise RuntimeError(f'timeout: size={size} scenario={scenario} {label}') from exc
                    metric = METRIC.search(result.stdout)
                    passed = PASS.search(result.stdout)
                    expected_duplicates = 1 if scenario == 'retry' else 0
                    if (result.returncode or metric is None or passed is None or
                            passed.group(1) != scenario or int(passed.group(2)) != 16 or
                            int(passed.group(3)) != 16 * size or int(passed.group(4)) != expected_duplicates or
                            int(metric.group(2)) != 16 * size or int(metric.group(3)) != 16):
                        print(result.stdout, file=sys.stderr)
                        raise RuntimeError(f'invalid result: size={size} scenario={scenario} {label} rc={result.returncode}')
                    seconds, mib, rate = float(metric.group(1)), float(metric.group(4)), float(metric.group(5))
                    raw_rows.append(['fifo', scenario, size, index + 1 if not warmup else index,
                                     int(warmup), 2, 16, seconds, mib, rate, round(wall, 6), 'PASS'])
                    print(f'  transfer={seconds:.6f}s wall={wall:.3f}s msgps={rate:.3f}', flush=True)
                    if not warmup:
                        times.append(seconds)
                        rates.append(rate)
                        bandwidths.append(mib)
                summaries.append(['fifo', scenario, size, len(times), statistics.median(times),
                                  percentile(times, .95), percentile(times, .99),
                                  statistics.median(rates), statistics.median(bandwidths),
                                  min(times), max(times), round(compile_wall, 6)])
                print(f'SUMMARY size={size} scenario={scenario} median={statistics.median(times):.6f}s '
                      f'p95={percentile(times, .95):.6f}s', flush=True)
    with args.output.open('w', newline='') as file:
        writer = csv.writer(file)
        writer.writerow(raw_fields)
        writer.writerows(raw_rows)
    with summary_path.open('w', newline='') as file:
        writer = csv.writer(file)
        writer.writerow(summary_fields)
        writer.writerows(summaries)
    print(f'PILOT_V3_DONE raw={args.output} summary={summary_path}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
