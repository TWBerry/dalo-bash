#!/usr/bin/env bash
# Compile and verify actual child-to-parent FIFO relay and endpoint acknowledgments.
# Parameters: $1 repository root (defaults to current working directory).
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
PROJECT="$ROOT/benchmarks/throughput/fifo-ack/probe.dalo"
IMAGE="$ROOT/benchmarks/throughput/fifo-ack/fifo_ack_probe.dalo.bash"
# Compile into a temporary project directory to avoid changing production files.
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cp "$ROOT/benchmarks/throughput/fifo-ack/"{probe.dalo,relay.bash,endpoint.bash} "$TMP/"
cp "$ROOT/benchmarks/parent-dispatch/noop.bash" "$TMP/noop.bash"
sed -i 's@../../parent-dispatch/noop.bash@noop.bash@' "$TMP/probe.dalo"
bash "$ROOT/compiler/daloc.bash" "$TMP/probe.dalo" >/dev/null
IMAGE="$TMP/fifo_ack_probe.dalo.bash"
bash -n "$IMAGE"
# The sourced generated image creates the canonical OBJECT FIFO descriptors.
source "$IMAGE"
DALO_BENCH_ENDPOINT_NS='' DALO_BENCH_PIPE_NS=''
for name_var in $(compgen -A variable); do
    [[ "$name_var" == *_OBJECT_NAME ]] || continue
    case "${!name_var:-}" in
        pipe) DALO_BENCH_PIPE_NS="${name_var%_OBJECT_NAME}" ;;
        endpoint) DALO_BENCH_ENDPOINT_NS="${name_var%_OBJECT_NAME}" ;;
    esac
done
[[ -n "$DALO_BENCH_PIPE_NS" && -n "$DALO_BENCH_ENDPOINT_NS" ]]
DALO_BENCH_PAYLOAD='abcdefghijklmnopqrstuvwxyz0123456789'
DALO_BENCH_ACK_COUNT=0 DALO_BENCH_ACK_BYTES=0 DALO_BENCH_ACK_LAST=0
# A real child process writes to the inherited PIPE FIFO; only the parent drains.
(
    for ((i=1;i<=16;i++)); do
        "${DALO_BENCH_PIPE_NS}_fifo_send" P pipe endpoint "$i|${DALO_BENCH_PAYLOAD:0:16}" || exit
    done
) &
child=$!
for ((attempt=0;attempt<500 && DALO_BENCH_ACK_COUNT<16;attempt++)); do
    "${DALO_BENCH_PIPE_NS}_drain_fifo"
    ((DALO_BENCH_ACK_COUNT == 16)) && break
    sleep 0.01
done
wait "$child"
[[ "$DALO_BENCH_ACK_COUNT" == 16 && "$DALO_BENCH_ACK_BYTES" == 256 && "$DALO_BENCH_ACK_LAST" == 16 ]] || {
    printf 'FAIL: ACK count=%s bytes=%s last=%s\n' "$DALO_BENCH_ACK_COUNT" "$DALO_BENCH_ACK_BYTES" "$DALO_BENCH_ACK_LAST" >&2
    exit 1
}
printf 'PASS: child PIPE -> FIFO -> parent relay -> ENDPOINT DATA -> 16 ACKs, 256 bytes\n'
