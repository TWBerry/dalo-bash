#!/usr/bin/env bash
# Test parent-owned cleanup after SIGKILL and generated pool reap wiring.
# Parameters: $1 repository root containing the installed incremental patch.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack-fifo
TMP="$(mktemp -d)"
child=''
# Ensure interrupted tests cannot leave a live child or temporary directory.
# Parameters: none.
cleanup() {
    if [[ -n "$child" ]]; then kill -KILL "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :; fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT
# Create an actual child that cannot perform cooperative EXIT cleanup.
# Parameters: none.
child_main() { exec sleep 30; }
child_main & child=$!
dalo_ack_register session client req1
dalo_ack_register session client req2
dalo_ack_endpoint_accept session client req1 payload
# The parent owns these pending entries and binds them to its child's PID.
dalo_ack_fifo_bind_child_pid "$child" session client
kill -KILL "$child"
rc=0
wait "$child" 2>/dev/null || rc=$?
[[ "$rc" == 137 ]]
dalo_child_reap_notify "$child" "$rc" m_0000_pipe 1
[[ ${#DALO_ACK_PENDING[@]} -eq 0 && -v DALO_ACK_APPLIED[session:client:req1] ]]
dalo_child_reap_notify "$child" "$rc" m_0000_pipe 1
[[ ${#DALO_ACK_PENDING[@]} -eq 0 ]]
late=0
dalo_ack_confirm session client req1 || late=$?
[[ "$late" == 4 ]]
child=''
printf 'PASS: SIGKILL child, parent cancels pending ACKs, late ACK rejected, dedup retained\n'
# Compile the existing real benchmark and inspect its generated pool reap path.
# Parameters: none; compiler output is temporary and never overwrites user data.
verify_generated() {
    local gen="$ROOT/benchmarks/throughput/throughput_benchmark.dalo.bash"
    [[ ! -e "$gen" ]] || { echo 'FAIL: generated benchmark exists; refusing overwrite' >&2; return 1; }
    trap "rm -f $(printf %q "$gen"); cleanup" EXIT
    bash "$ROOT/compiler/daloc.bash" "$ROOT/benchmarks/throughput/benchmark.dalo" >/dev/null
    grep -q 'dalo_child_reap_notify' "$gen"
    bash -n "$gen"
    printf 'PASS: generated MACHINE notifies parent-side child reap hooks\n'
}
verify_generated
dalo_library_fini_all
