# DALO throughput benchmark v2

Status: **matrix and compilable DIRECT topology scaffold only; not a working throughput benchmark**.
Do not interpret matrix output as measured performance.

## Fixed test matrix

- DIRECT: `ORIGIN -> PIPE -> ENDPOINT`, sizes 1, 2, 4, ..., 65536 bytes;
  256 batches per size.
- FIFO: `ORIGIN -> PIPE -> parent FIFO relay -> ENDPOINT`, sizes 1, 2,
  4, ..., 2048 bytes; 64 batches per size.
- Worker counts: 1, 2, 3, 4 per data OBJECT, changed together.
- Python timing: `time.perf_counter_ns()` in a reserved persistent worker.
  Distinguish source enqueue, endpoint acknowledgment and controller overhead.
- Controller: the existing scheduler must report current phase, sizes, workers,
  progress, latency distribution and throughput. Avoid stdout inside timed spans.
- Payload: one immutable byte sequence of at least 65536 bytes; each message
  contains its prefix of the requested size. Acknowledge receipt before reuse.

## Current architecture constraints

`docs/compiler.md` explicitly reserves object FIFO for child-to-parent control,
not the DATA graph. The parser currently supports `WORKER CODE/TYPE/EXECUTION`
but no declarative parent-forwarding rule. The FIFO phase therefore requires
an approved generic descriptor and compiler/runtime implementation; silently
using direct DATA transport would invalidate the measurement.

A scheduler already exists as a per-MACHINE authority (`definitions/objects/scheduler.json`),
but the current descriptor is not a benchmark controller. A generic controller
extension should be implemented without hard-coding benchmark OBJECT names.

## Run current scaffold

```sh
python3 benchmarks/throughput/matrix.py
python3 benchmarks/throughput/matrix.py --json
bash compiler/daloc.bash benchmarks/throughput/benchmark.dalo
```

## Acceptance criteria for implementation

1. Both data paths deliver byte-exact prefixes and return per-batch acknowledgments.
2. The scheduler advances only after the previous phase completes.
3. Every result carries mode, payload size, worker count and measured interval.
4. Validate warmup exclusion, `min`, median, p95, p99, max, MiB/s and messages/s.
5. Preserve AB/BA and disconnect/reconnect regressions.
6. Run at least three independent repetitions before making performance claims.
