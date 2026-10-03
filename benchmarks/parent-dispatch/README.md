# Parent dispatch compiler smoke test

Compile with `bash compiler/daloc.bash benchmarks/parent-dispatch/parent-dispatch.dalo`.
The generated MACHINE should pass `bash -n`. `parent.bash` and `hook.bash`
are sample parent handler bodies, not a performance benchmark. The
scheduler-controlled throughput benchmark and FIFO ACK timing are separate
follow-up work.
