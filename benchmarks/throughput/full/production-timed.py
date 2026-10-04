#!/usr/bin/env python3
"""Run bounded production DALO pilots, recording preparation and execution separately.

Each run is a fresh shell invocation. Results are appended immediately; incomplete
or failed configurations remain visible and can be retried without losing data.
"""
import argparse
import csv
import os
from pathlib import Path
import re
import subprocess
import time

FIELDS = ('mode', 'workers', 'messages', 'payload_bytes', 'repeat', 'status',
          'wall_seconds', 'reported_seconds', 'unique', 'duplicates', 'msgps', 'detail')
PASS = re.compile(r'PASS mode=(\w+) workers=(\d+) unique=(\d+) bytes=(\d+) duplicates=(\d+) seconds=([0-9.]+) msgps=([0-9.]+)')


def read_existing(path):
    """Read successful run identities from path, the CSV checkpoint file."""
    if not path.exists():
        return set()
    with path.open(newline='') as stream:
        return {(r['mode'], int(r['workers']), int(r['messages']),
                 int(r['payload_bytes']), int(r['repeat']))
                for r in csv.DictReader(stream) if r['status'] == 'PASS'}


def run_one(root, mode, workers, messages, size, repeat, timeout):
    """Execute one bounded pilot; all arguments specify its configuration or limit."""
    script = root / 'tests' / ('test-production-persistent-pilot-unbatched.sh'
                               if mode == 'direct' else 'test-production-persistent-fifo.sh')
    if not script.is_file():
        return dict(status='UNAVAILABLE', wall_seconds=0, reported_seconds='',
                    unique='', duplicates='', msgps='', detail=f'missing runner: {script}')
    env = dict(os.environ, DALO_PILOT_WORKERS=str(workers),
               DALO_PILOT_MESSAGES=str(messages), DALO_PILOT_BYTES=str(size))
    start = time.monotonic()
    try:
        result = subprocess.run(['bash', str(script)], cwd=root, env=env,
                                capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        return dict(status='TIMEOUT', wall_seconds=round(time.monotonic()-start, 4),
                    reported_seconds='', unique='', duplicates='', msgps='',
                    detail=f'exceeded {timeout}s; stdout={str(exc.stdout)[-150:]}')
    wall = round(time.monotonic()-start, 4)
    match = PASS.search(result.stdout)
    if result.returncode or not match:
        return dict(status='FAIL', wall_seconds=wall, reported_seconds='', unique='',
                    duplicates='', msgps='', detail=(result.stdout+' '+result.stderr)[-350:])
    actual_mode, actual_workers, unique, actual_bytes, duplicates, seconds, msgps = match.groups()
    valid = (actual_mode == mode and int(actual_workers) == workers and
             int(unique) == messages and int(actual_bytes) == messages*size and
             int(duplicates) == 0)
    return dict(status='PASS' if valid else 'FAIL', wall_seconds=wall,
                reported_seconds=seconds, unique=unique, duplicates=duplicates,
                msgps=msgps, detail='' if valid else 'runner reported inconsistent result')


def main():
    """Parse CLI arguments and execute checkpointed runs; parameters come from CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--output', type=Path, default=Path('production-timed.csv'))
    parser.add_argument('--mode', choices=('direct', 'fifo', 'both'), default='both')
    parser.add_argument('--workers', type=int, nargs='+', default=[1, 2, 4])
    parser.add_argument('--sizes', type=int, nargs='+', default=[8, 128])
    parser.add_argument('--messages', type=int, default=32)
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--timeout', type=float, default=30)
    args = parser.parse_args()
    if (not all(1 <= w <= 4 for w in args.workers) or
            not all(1 <= s <= 2048 for s in args.sizes) or
            args.messages < 1 or args.repeats < 1 or args.timeout <= 0):
        parser.error('invalid workload or timeout')
    root = args.root.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    done = read_existing(args.output)
    modes = ('direct', 'fifo') if args.mode == 'both' else (args.mode,)
    with args.output.open('a', newline='', buffering=1) as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        if stream.tell() == 0:
            writer.writeheader()
        for mode in modes:
            for workers in args.workers:
                for size in args.sizes:
                    for repeat in range(args.repeats):
                        key = (mode, workers, args.messages, size, repeat)
                        if key in done:
                            print('SKIP', key, flush=True)
                            continue
                        row = dict(zip(FIELDS[:5], key))
                        row.update(run_one(root, *key, args.timeout))
                        writer.writerow(row)
                        stream.flush()
                        os.fsync(stream.fileno())
                        print(row['status'], key, f"wall={row['wall_seconds']}s", flush=True)
                        if row['status'] == 'UNAVAILABLE':
                            print('FIFO runner not integrated; no fabricated measurements.', flush=True)
                            break


if __name__ == '__main__':
    main()
