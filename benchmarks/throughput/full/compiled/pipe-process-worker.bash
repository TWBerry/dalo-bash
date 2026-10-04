#!/usr/bin/env bash
# Persistent child executor for the compiled PIPE OBJECT.WORKER.
# Parameter $1: zero-based worker lane; $2: path to the generated MACHINE image.
set -euo pipefail
lane="${1:-}" image="${2:-}"
[[ "$lane" =~ ^[0-3]$ && -r "$image" ]] || exit 64

# The generated MACHINE is the single authority for OBJECT.WORKER code.
# Sourcing it materializes its worker functions in this child process.
source "$image" >/dev/null
pipe_ns='' endpoint_ns=''
for name_var in $(compgen -A variable); do
    [[ "$name_var" == *_OBJECT_NAME ]] || continue
    case "${!name_var:-}" in
        pipe) pipe_ns="${name_var%_OBJECT_NAME}" ;;
        endpoint) endpoint_ns="${name_var%_OBJECT_NAME}" ;;
    esac
done
[[ -n "$pipe_ns" && -n "$endpoint_ns" ]] || exit 70

# The compiled PIPE worker calls its downstream object. In the child, replace
# only the downstream delivery boundary with a response-channel adapter.
# Parameters: $1 input port; $2 processed frame.
dalo_bench_child_endpoint_summon_worker() {
    local port="${1:-}" frame="${2:-}" seq
    [[ "$port" == in && "$frame" == *'|'* ]] || return 81
    seq="${frame%%|*}"
    [[ "$seq" =~ ^[1-9][0-9]*$ ]] || return 82
    printf '%s\t%s\t%s\n' "$seq" "$BASHPID" "$frame"
}
DALO_BENCH_PIPE_CHILD=1
DALO_BENCH_ENDPOINT_NS=dalo_bench_child_endpoint
# Signal readiness only after sourcing the compiled MACHINE and installing adapters.
printf 'READY\n'

# Invoke the generated worker function for each request, preserving its
# standard (worker_dir, slot, input) calling convention.
# Protocol parameters: tab-delimited sequence and encoded ASCII frame.
while IFS=$'\t' read -r seq encoded; do
    [[ "$seq" =~ ^[1-9][0-9]*$ && "$encoded" == *_* ]] || exit 65
    frame="${encoded/_/|}"
    [[ "${frame%%|*}" == "$seq" ]] || exit 66
    "${pipe_ns}_worker" "${TMPDIR:-/tmp}" "$seq" "$frame" || exit
 done
