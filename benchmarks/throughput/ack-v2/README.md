# DALO FIFO ACK Protocol v2 — integration probe

This standalone probe extends the existing asynchronous ACK test with per-client
request IDs, endpoint-side deduplication, first-ACK loss injection, and bounded
retransmission of unacknowledged requests. ACK is sent only after ENDPOINT
accepts the frame. The two real child processes use dedicated ACK FIFOs.

Run from the DALO repository root:

```bash
bash benchmarks/throughput/ack-v2/test.sh "$PWD"
bash benchmarks/throughput/ack-v2/test.sh "$PWD" retry
```

`retry` suppresses the first ACK for request `2:4`, forces retransmission,
and asserts that ENDPOINT applies its payload only once. Other pending
requests may also be retransmitted after the timeout; their duplicate
processing is suppressed. All 16 unique frames must be acknowledged.

This is an isolated integration probe, **not** the production generic ACK ABI.
It does not yet cover persistent request IDs across restart, crash recovery,
network partitions, delayed/stale ACKs, or benchmark timing. Production compiler
and runtime files are unchanged.
