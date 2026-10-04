#!/usr/bin/env bash
# Verify generated MACHINE pre-stop integration and ACK cancellation isolation.
# Parameters: $1 root of the repository with the installed patch.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack-fifo
# A WORKER can own more than one ACK client and must cancel only its bindings.
dalo_ack_fifo_bind_worker m_0000_origin run client1
dalo_ack_fifo_bind_worker m_0000_origin run client2
dalo_ack_fifo_bind_worker m_0001_pipe run other
dalo_ack_register run client1 req1
dalo_ack_register run client2 req2
dalo_ack_register run other req3
dalo_ack_endpoint_accept run client1 req1 fingerprint
# The generated MACHINE's stop-all function calls the generic hook.
dalo_worker_stop_notify m_0000_origin
[[ ! -v DALO_ACK_PENDING[run:client1:req1] && ! -v DALO_ACK_PENDING[run:client2:req2] ]]
[[ -v DALO_ACK_PENDING[run:other:req3] && -v DALO_ACK_APPLIED[run:client1:req1] ]]
dalo_worker_stop_notify m_0000_origin
[[ -v DALO_ACK_PENDING[run:other:req3] ]]
# A stopped WORKER must reject new bindings.
if dalo_ack_fifo_bind_worker m_0000_origin run late; then echo 'FAIL: binding after stop' >&2; exit 1; fi
dalo_worker_stop_notify m_0001_pipe
[[ ${#DALO_ACK_PENDING[@]} -eq 0 ]]
printf 'PASS: pre-stop ACK cancellation, multiple clients, isolation, idempotence\n'
# Compile a real MACHINE and verify that its emitted lifecycle calls the hook.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT/benchmarks/throughput/benchmark.dalo" "$TMP/benchmark.dalo"
# Original benchmark uses relative worker paths, so compile it in place and
# remove only the generated file if it did not exist before this test.
GEN="$ROOT/benchmarks/throughput/throughput_benchmark.dalo.bash"
[[ ! -e "$GEN" ]] || { echo 'FAIL: generated MACHINE already exists; refusing overwrite' >&2; exit 1; }
trap 'rm -f "$GEN"; rm -rf "$TMP"' EXIT
bash "$ROOT/compiler/daloc.bash" "$ROOT/benchmarks/throughput/benchmark.dalo" >/dev/null
[[ -f "$GEN" ]]
grep -q 'dalo_worker_stop_notify m_0000_origin' "$GEN"
bash -n "$GEN"
printf 'PASS: generated MACHINE includes generic pre-stop hook\n'
dalo_library_fini_all
