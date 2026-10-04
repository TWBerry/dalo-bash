#!/usr/bin/env bash
# Exercise the real DALO asynchronous pool after a SIGKILLed worker and verify
# that the same slot can accept and complete a replacement job.
# Parameters: $1 repository root containing the installed ACK and runtime patches.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
TMP="$(mktemp -d)"
export MAIN_TMP_DIR="$TMP"
child=''
# Terminate any remaining worker and remove test-owned FIFO resources.
# Parameters: none.
cleanup() {
    if [[ -n "$child" ]]; then kill -KILL "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT
source "$ROOT/runtime/library.sh"
include ack-fifo
# Load the generator directly in this isolated test to avoid starting Python.
source "$ROOT/runtime/dalo.bashlib.sh"
asyncobj_constructor testpool
testpool_job_pool_init 1
# Block the first worker until the parent kills it; it must not run EXIT cleanup.
# Parameters: $1 worker directory; $2 pool slot; $3+ job arguments.
blocked_worker() {
    exec sleep 30
}
# Complete the replacement worker normally and leave a visible completion marker.
# Parameters: $1 worker directory; $2 pool slot; $3+ job arguments.
replacement_worker() {
    printf 'replacement:%s\n' "$2" >"$MAIN_TMP_DIR/replacement.done"
}
testpool_job_pool_submit_port in blocked_worker '' first
child="${testpool_WORKER_PIDS[1]}"
[[ -n "$child" && "${testpool_PENDING_JOBS}" == 1 ]]
dalo_ack_register session client req1
dalo_ack_register session client req2
dalo_ack_endpoint_accept session client req1 fingerprint
dalo_ack_fifo_bind_child_pid "$child" session client
kill -KILL "$child"
# The real pool's reap path invokes ACK cleanup and its real scheduler release.
# Parameters: none.
testpool_job_pool_wait
[[ "${testpool_PENDING_JOBS}" == 0 && ${#DALO_ACK_PENDING[@]} == 0 ]]
[[ -v DALO_ACK_APPLIED[session:client:req1] ]]
[[ -z "${testpool_WORKER_PIDS[1]:-}" ]]
[[ "${testpool_JOB_STATUS_VECTOR[1]}" == ABNORMAL_TERMINATION ]]
late=0
dalo_ack_confirm session client req1 || late=$?
[[ "$late" == 4 ]]
child=''
# The replacement uses the released real pool slot, not a test-double release.
testpool_job_pool_submit_port in replacement_worker '' second
replacement_pid="${testpool_WORKER_PIDS[1]}"
[[ -n "$replacement_pid" ]]
testpool_job_pool_wait
[[ "${testpool_PENDING_JOBS}" == 0 ]]
[[ "${testpool_JOB_STATUS_VECTOR[1]}" == SUCCESS ]]
[[ "$(cat "$TMP/replacement.done")" == replacement:1 ]]
[[ -z "${testpool_WORKER_PIDS[1]:-}" ]]
printf 'PASS: real async pool, SIGKILL, ACK cancellation, actual slot release and successful replacement\n'
dalo_library_fini_all
