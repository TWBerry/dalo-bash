# Compiled single-MACHINE benchmark integration v1

The `.dalo` project declares the parent custom scheduler and real ORIGIN and ENDPOINT workers. `run.sh` compiles it through `daloc` and runs real generated DIRECT and FIFO paths. No synthetic delivery metrics. For FIFO, 1–4 real producer processes share the compiled MACHINE FIFO; the parent dispatches and validates all messages. DIRECT currently executes in the parent only: the producer count is **not** real DIRECT worker scaling. This is an integration milestone, **not** the complete 116-configuration benchmark or a full persistent 1–4 worker/object implementation. Each `run.sh` invocation sources a new MACHINE; the message loop is persistent within that run. Timing includes only the message loop, not compilation or initialization. The FIFO drain may still poll. No claims of completed full benchmark.

Install over current tree and run:

```bash
bash benchmarks/throughput/full/compiled/run.sh direct 64 16 1
bash benchmarks/throughput/full/compiled/run.sh fifo 64 16 1
bash benchmarks/throughput/full/compiled/run.sh fifo 64 16 4
```
