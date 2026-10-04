# DALO FIFO endpoint acknowledgment integration probe

This probe validates the real child PIPE -> inherited FIFO -> MACHINE parent
worker -> ENDPOINT public DATA input path. ENDPOINT validates sequence and
payload and records one acknowledgment per delivered frame in the parent.

Run from repository root:

```bash
bash benchmarks/throughput/fifo-ack/test.sh "$PWD"
```

Expected: `PASS: child PIPE -> FIFO -> parent relay -> ENDPOINT DATA -> 16 ACKs, 256 bytes`.

The test compiles a temporary MACHINE and changes no production compiler or
runtime files. This is a functional integration probe, **not** a throughput
benchmark: its acknowledgments are parent-visible synchronous counters, not
a production asynchronous ACK protocol. Next: add explicit per-frame ACK
transport, failure/timeout handling, then scheduler-controlled timing.
