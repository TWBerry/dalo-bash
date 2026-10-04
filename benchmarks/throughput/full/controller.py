#!/usr/bin/env python3
"""Deterministic, resumable DALO DIRECT/FIFO benchmark result controller.

This controller does not implement a transport or synthesize performance results.
Actual runners must submit one JSON result per completed configuration/repetition.
"""
import argparse
import csv
import json
import math
import statistics
from pathlib import Path
from matrix import build_matrix

FIELDS = ('mode', 'workers_per_object', 'bytes', 'batches', 'repetition',
          'warmup', 'seconds', 'unique', 'received_bytes', 'duplicates', 'status')


def validate(row, expected, repetitions, warmups):
    """Validate one transport-produced result; row is the result and expected is its matrix configuration.

    repetitions is the measured run count; warmups is the excluded run count.
    """
    for name in FIELDS:
        if name not in row:
            raise ValueError(f'missing field: {name}')
    for name in ('mode', 'workers_per_object', 'bytes', 'batches'):
        if row[name] != expected[name]:
            raise ValueError(f'configuration mismatch: {name}')
    if type(row['repetition']) is not int or not -warmups <= row['repetition'] < repetitions:
        raise ValueError('invalid repetition index')
    if type(row['warmup']) is not bool or row['warmup'] != (row['repetition'] < 0):
        raise ValueError('warmup flag does not match repetition')
    if not isinstance(row['seconds'], (int, float)) or not math.isfinite(row['seconds']) or row['seconds'] <= 0:
        raise ValueError('invalid elapsed time')
    if row['status'] != 'PASS' or row['unique'] != expected['batches'] or row['received_bytes'] != expected['batches'] * expected['bytes']:
        raise ValueError('delivery validation failed')
    if type(row['duplicates']) is not int or row['duplicates'] != 0:
        raise ValueError('baseline run unexpectedly duplicated messages')


def nearest_rank(values, fraction):
    """Calculate nearest-rank percentile; values are samples and fraction is in (0,1]."""
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * fraction) - 1]


def summarize(rows, expected, repetitions):
    """Summarize measured rows; rows excludes warmups, expected is the matrix entry, repetitions is the target count."""
    if len(rows) != repetitions:
        raise ValueError('configuration has incomplete measurements')
    durations = [row['seconds'] for row in rows]
    total_bytes = expected['bytes'] * expected['batches']
    return dict(expected, repetitions=repetitions, min_seconds=min(durations),
                median_seconds=statistics.median(durations),
                p95_seconds=nearest_rank(durations, .95),
                p99_seconds=nearest_rank(durations, .99), max_seconds=max(durations),
                median_messages_per_second=statistics.median(expected['batches'] / t for t in durations),
                median_mib_per_second=statistics.median(total_bytes / t / 1048576 for t in durations))


def main():
    """Generate a plan or validate/aggregate runner results; command-line options select mode, input and output."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('plan', 'aggregate'), required=True)
    parser.add_argument('--results', type=Path, help='JSONL from actual transport runners')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--warmups', type=int, default=2)
    args = parser.parse_args()
    if args.repetitions < 3 or args.warmups < 0:
        parser.error('repetitions >= 3 and warmups >= 0 required')
    matrix = build_matrix()
    expected = {(item['mode'], item['workers_per_object'], item['bytes']): item for item in matrix}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.mode == 'plan':
        with args.output.open('w') as output:
            for item in matrix:
                for rep in range(-args.warmups, args.repetitions):
                    output.write(json.dumps(dict(item, repetition=rep, warmup=rep < 0)) + '\n')
        print(f'PLAN configurations={len(matrix)} runs={len(matrix) * (args.repetitions + args.warmups)} output={args.output}')
        return
    if not args.results or not args.results.is_file():
        parser.error('aggregate requires an existing --results JSONL file')
    grouped = {}
    with args.results.open() as source:
        for line_no, line in enumerate(source, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            key = (row.get('mode'), row.get('workers_per_object'), row.get('bytes'))
            if key not in expected:
                raise ValueError(f'line {line_no}: unexpected configuration {key}')
            validate(row, expected[key], args.repetitions, args.warmups)
            bucket = grouped.setdefault(key, {})
            if row['repetition'] in bucket:
                raise ValueError(f'line {line_no}: duplicate repetition for {key}')
            bucket[row['repetition']] = row
    summary = []
    for key, item in expected.items():
        bucket = grouped.get(key, {})
        if len(bucket) != args.repetitions + args.warmups:
            raise ValueError(f'incomplete configuration {key}: {len(bucket)} runs')
        summary.append(summarize([bucket[i] for i in range(args.repetitions)], item, args.repetitions))
    with args.output.open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=tuple(summary[0]))
        writer.writeheader()
        writer.writerows(summary)
    print(f'PASS configurations={len(summary)} validated_runs={sum(map(len, grouped.values()))} output={args.output}')


if __name__ == '__main__':
    main()
