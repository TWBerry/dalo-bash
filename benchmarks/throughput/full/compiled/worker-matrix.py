#!/usr/bin/env python3
"""Repeated, randomized PIPE x ENDPOINT scaling for the compiled DALO MACHINE.

Each sample launches the actual compiled MACHINE. This runner does not modify
production scheduling, and worker counts denote real persistent process pools.
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
PATTERN = re.compile(r'PASS mode=(direct|fifo) endpoint_workers=(\d+) pipe_workers=(\d+) producers=(\d+) unique=(\d+) bytes=(\d+) duplicates=(\d+) seconds=([0-9.]+) msgps=([0-9.]+)')
RAW_FIELDS = ('round', 'mode', 'pipe_workers', 'endpoint_workers', 'producers', 'messages', 'payload_bytes', 'bytes', 'duplicates', 'seconds', 'msgps', 'divisible')
SUMMARY_FIELDS = ('mode', 'pipe_workers', 'endpoint_workers', 'producers', 'samples', 'divisible', 'median_msgps', 'min_msgps', 'max_msgps', 'median_seconds', 'p95_seconds')


def positive(value):
    """Parse a positive integer; value is the user-supplied CLI argument."""
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return number


def parse_counts(value):
    """Validate worker counts; value is a comma-separated list of integers 1..4."""
    try:
        counts = [int(item) for item in value.split(',')]
    except ValueError as exc:
        raise argparse.ArgumentTypeError('expected comma-separated integers') from exc
    if not counts or len(counts) != len(set(counts)) or any(n not in (1, 2, 3, 4) for n in counts):
        raise argparse.ArgumentTypeError('counts must be unique integers in 1..4')
    return counts


def sample(script, mode, pipe, endpoint, producers, messages, payload, timeout):
    """Run and verify one real MACHINE; parameters specify runner, topology and load."""
    command = ['bash', str(script), mode, str(messages), str(payload), str(endpoint), str(producers), str(pipe)]
    process = subprocess.run(command, cwd=script.parent, capture_output=True, text=True, timeout=timeout)
    match = PATTERN.search(process.stdout)
    if process.returncode or match is None:
        raise RuntimeError(f'command={command!r} exit={process.returncode}\nstdout={process.stdout}\nstderr={process.stderr}')
    got_mode, got_endpoint, got_pipe, got_producers, unique, byte_count, duplicates = match.groups()[:7]
    seconds, msgps = map(float, match.groups()[7:])
    expected = (mode, endpoint, pipe, producers, messages, messages * payload, 0)
    actual = (got_mode, int(got_endpoint), int(got_pipe), int(got_producers), int(unique), int(byte_count), int(duplicates))
    if actual != expected or seconds <= 0 or not math.isfinite(seconds) or not math.isfinite(msgps) or abs(msgps - messages / seconds) > max(0.1, msgps * 0.0001):
        raise RuntimeError(f'incorrect delivery or timing: expected={expected} actual={actual} stdout={process.stdout}')
    return dict(mode=mode, pipe_workers=pipe, endpoint_workers=endpoint, producers=producers,
                messages=messages, payload_bytes=payload, bytes=byte_count, duplicates=duplicates,
                seconds=seconds, msgps=msgps, divisible=int(pipe % endpoint == 0 or endpoint % pipe == 0))


def summarize(rows, configurations):
    """Aggregate measured samples; rows are raw samples and configurations define order."""
    result = []
    for mode, pipe, endpoint in configurations:
        subset = [r for r in rows if (r['mode'], r['pipe_workers'], r['endpoint_workers']) == (mode, pipe, endpoint)]
        speeds = [r['msgps'] for r in subset]
        times = sorted(r['seconds'] for r in subset)
        result.append(dict(mode=mode, pipe_workers=pipe, endpoint_workers=endpoint,
                           producers=subset[0]['producers'], samples=len(subset), divisible=subset[0]['divisible'],
                           median_msgps=round(statistics.median(speeds), 3), min_msgps=round(min(speeds), 3),
                           max_msgps=round(max(speeds), 3), median_seconds=round(statistics.median(times), 6),
                           p95_seconds=round(times[math.ceil(.95 * len(times)) - 1], 6)))
    return result


def main(argv=None):
    """Compile once and execute shuffled warmup and measured rounds; argv is optional CLI args."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--counts', type=parse_counts, default=[1, 2, 3, 4])
    parser.add_argument('--modes', default='direct,fifo')
    parser.add_argument('--messages', type=positive, default=1024)
    parser.add_argument('--payload', type=positive, default=16)
    parser.add_argument('--fifo-producers', type=positive, default=2)
    parser.add_argument('--warmups', type=int, default=2)
    parser.add_argument('--repetitions', type=positive, default=7)
    parser.add_argument('--timeout', type=positive, default=180)
    parser.add_argument('--seed', type=int, default=20261003)
    parser.add_argument('--output', type=Path, default=Path('worker-matrix-raw.csv'))
    parser.add_argument('--summary', type=Path, default=Path('worker-matrix-summary.csv'))
    parser.add_argument('--no-compile', action='store_true', help='Use already compiled image')
    args = parser.parse_args(argv)
    modes = args.modes.split(',')
    if not modes or len(set(modes)) != len(modes) or any(mode not in ('direct', 'fifo') for mode in modes):
        parser.error('modes must be direct,fifo or a subset')
    if args.warmups < 0 or args.messages > 100000 or args.payload > 65536 or args.fifo_producers > 4:
        parser.error('invalid warmups/messages/payload/producers')
    if 'fifo' in modes and args.payload > 256:
        parser.error('FIFO payload >256 B may exceed PIPE_BUF=512; use a smaller payload')
    if not args.no_compile:
        project = HERE / 'benchmark.dalo'
        compiler = HERE.parents[3] / 'compiler' / 'daloc.bash'
        subprocess.run(['bash', str(compiler), str(project)], cwd=HERE, check=True)
    elif not (HERE / 'dalo_full_benchmark.dalo.bash').exists():
        parser.error('--no-compile requires an existing compiled image')
    configurations = [(mode, pipe, endpoint) for mode in modes for pipe in args.counts for endpoint in args.counts]
    rng = random.Random(args.seed)
    rows = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=RAW_FIELDS)
        writer.writeheader()
        for round_number in range(-args.warmups, args.repetitions):
            order = configurations[:]
            rng.shuffle(order)
            for mode, pipe, endpoint in order:
                label = 'warmup' if round_number < 0 else f'round {round_number + 1}'
                print(f'{label}: {mode} PIPE={pipe} ENDPOINT={endpoint}', flush=True)
                try:
                    result = sample(HERE / 'run-workers.sh', mode, pipe, endpoint,
                                    args.fifo_producers if mode == 'fifo' else 1,
                                    args.messages, args.payload, args.timeout)
                except (RuntimeError, subprocess.TimeoutExpired) as exc:
                    print(f'FAIL: {exc}; completed raw samples retained in {args.output}', file=sys.stderr)
                    return 1
                if round_number >= 0:
                    writer.writerow(dict(round=round_number + 1, **result))
                    stream.flush()
                    rows.append(result)
                    print(f'  {result["msgps"]:.1f} msg/s', flush=True)
    summary = summarize(rows, configurations)
    with args.summary.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        writer.writerows(summary)
    print(f'PASS configurations={len(configurations)} measured={len(rows)} warmups={len(configurations) * args.warmups} raw={args.output} summary={args.summary}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
