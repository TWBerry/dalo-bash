#!/usr/bin/env python3
"""Measure DALO benchmark phases without changing production runtime semantics."""
import argparse
import csv
import os
from pathlib import Path
import re
import subprocess
import time

FIELDS = ('workers', 'messages', 'payload_bytes', 'repeat', 'status',
          'wall_seconds', 'compile_seconds', 'init_seconds', 'submit_seconds',
          'wait_seconds', 'stop_seconds', 'reported_seconds', 'detail')
PHASE = re.compile(r'^PHASE ([a-z_]+)=([0-9.]+)$', re.MULTILINE)
PASS = re.compile(r'PASS mode=direct workers=(\d+) unique=(\d+) bytes=(\d+) duplicates=(\d+) seconds=([0-9.]+)')


def measure(root, workers, messages, size, timeout):
    """Run one isolated fixture; root is the repository, remaining args define its workload and timeout."""
    env = dict(os.environ, DALO_PILOT_WORKERS=str(workers),
               DALO_PILOT_MESSAGES=str(messages), DALO_PILOT_BYTES=str(size))
    start = time.monotonic()
    proc = subprocess.Popen(['bash', str(root / 'tests/test-production-persistent-pilot-phases.sh')],
                            cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        import signal
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        return dict(status='TIMEOUT', wall_seconds=round(time.monotonic()-start, 4),
                    detail=f'exceeded {timeout}s')
    result = type('Result', (), {'stdout': stdout, 'stderr': stderr, 'returncode': proc.returncode})
    wall = round(time.monotonic()-start, 4)
    marks = {name: float(value) for name, value in PHASE.findall(result.stderr)}
    match = PASS.search(result.stdout)
    valid = bool(match and result.returncode == 0 and int(match[1]) == workers
                 and int(match[2]) == messages and int(match[3]) == messages*size
                 and int(match[4]) == 0)
    row = dict(status='PASS' if valid else 'FAIL', wall_seconds=wall,
               reported_seconds=match[5] if match else '',
               detail='' if valid else (result.stdout + result.stderr)[-500:])
    for label, first, last in (('compile', 'compile_start', 'compile_end'),
                               ('init', 'init_start', 'init_end'),
                               ('submit', 'submit_start', 'submit_end'),
                               ('wait', 'submit_end', 'wait_end'),
                               ('stop', 'stop_start', 'stop_end')):
        row[label + '_seconds'] = round(marks[last]-marks[first], 6) if first in marks and last in marks else ''
    return row


def main():
    """Run checkpointed timing experiments; all configuration parameters are supplied by CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--output', type=Path, default=Path('production-phases.csv'))
    parser.add_argument('--workers', type=int, nargs='+', default=[2, 4])
    parser.add_argument('--sizes', type=int, nargs='+', default=[8, 128])
    parser.add_argument('--messages', type=int, default=32)
    parser.add_argument('--repeats', type=int, default=1)
    parser.add_argument('--timeout', type=float, default=45)
    args = parser.parse_args()
    if not all(1 <= w <= 4 for w in args.workers) or not all(1 <= s <= 2048 for s in args.sizes) or args.messages < 1 or args.repeats < 1 or args.timeout <= 0:
        parser.error('invalid benchmark configuration')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    done = set()
    if args.output.exists():
        with args.output.open(newline='') as stream:
            done = {(int(r['workers']), int(r['messages']), int(r['payload_bytes']), int(r['repeat']))
                    for r in csv.DictReader(stream) if r['status'] == 'PASS'}
    with args.output.open('a', newline='', buffering=1) as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        if stream.tell() == 0:
            writer.writeheader()
        for workers in args.workers:
            for size in args.sizes:
                for repeat in range(args.repeats):
                    key = (workers, args.messages, size, repeat)
                    if key in done:
                        print('SKIP', key, flush=True)
                        continue
                    row = dict(zip(FIELDS[:4], key))
                    row.update(measure(args.root.resolve(), workers, args.messages, size, args.timeout))
                    writer.writerow(row)
                    stream.flush()
                    os.fsync(stream.fileno())
                    print(row['status'], key, 'wall=', row['wall_seconds'], 'phases=',
                          {k: row[k] for k in FIELDS[6:11]}, flush=True)


if __name__ == '__main__':
    main()
