#!/usr/bin/env bash
# Exercise a generated DALO pool reap function with a real SIGKILLed child.
# Parameters: $1 root of the installed DALO repository.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack-fifo
include dalo
TMP="$(mktemp -d)"
child=''
# Remove temporary resources and any child still running after a test failure.
# Parameters: none.
cleanup() {
    if [[ -n "$child" ]]; then kill -KILL "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT
# Construct the actual pool reap function using the runtime's code generator.
# Parameters: $1 pool namespace.
define_mark_reaped testpool
declare -a testpool_WORKER_PIDS=() testpool_REAPED_PIDS=() testpool_REAP_EXIT_CODES=()
testpool_MAX_JOBS=1
RELEASES=0
# Record that the pool reached its slot-release path after notifying hooks.
# Parameters: $1 slot number; $2 child PID.
testpool_try_release_slot() {
    [[ "$1" == 1 && "$2" == "$child" ]] || return 1
    [[ ${#DALO_ACK_PENDING[@]} -eq 0 ]] || { echo 'FAIL: slot released before ACK cancellation' >&2; return 1; }
    ((RELEASES+=1))
}
# Spawn a child that cannot execute cooperative EXIT or TERM handlers.
# Parameters: none.
child_main() { exec sleep 30; }
child_main & child=$!
testpool_WORKER_PIDS[1]="$child"
dalo_ack_register run client request1
dalo_ack_register run client request2
dalo_ack_endpoint_accept run client request1 fingerprint
dalo_ack_fifo_bind_child_pid "$child" run client
kill -KILL "$child"
rc=0
wait "$child" 2>/dev/null || rc=$?
[[ "$rc" == 137 ]] || { echo "FAIL: unexpected child status $rc" >&2; exit 1; }
testpool_mark_reaped "$child" "$rc"
[[ "$RELEASES" == 1 && ${#DALO_ACK_PENDING[@]} -eq 0 ]]
[[ -v DALO_ACK_APPLIED[run:client:request1] ]]
[[ ${testpool_REAPED_PIDS[1]} == "$child" && ${testpool_REAP_EXIT_CODES[1]} == 137 ]]
late=0
dalo_ack_confirm run client request1 || late=$?
[[ "$late" == 4 ]]
# A duplicate reap notification must not run the callback or release twice.
# Parameters: none.
testpool_mark_reaped "$child" "$rc"
[[ "$RELEASES" == 1 && ${#DALO_ACK_PENDING[@]} -eq 0 ]]
child=''
dalo_library_fini_all
printf 'PASS: generated pool reap function, real SIGKILL, parent ACK cancellation before slot release, late ACK rejected\n'
