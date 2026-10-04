# DALO asynchronous FIFO ACK integration probe v1

Two real concurrent child processes each enqueue eight uniquely identified frames
through the existing PIPE FIFO. The parent relays them into ENDPOINT's public DATA
input and sends explicit ACK frames through dedicated per-child FIFOs only after
endpoint acceptance. Children independently validate ACK IDs and use bounded reads.

Run from repository root:

```bash
bash benchmarks/throughput/async-ack/test.sh "$PWD"
bash benchmarks/throughput/async-ack/test.sh "$PWD" drop
```

The `drop` scenario intentionally suppresses one ACK and requires a child timeout.
No production compiler/runtime files are modified. This is an integration probe,
not yet the production generic ACK ABI, retry protocol or throughput benchmark.
