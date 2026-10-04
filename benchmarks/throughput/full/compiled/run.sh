#!/usr/bin/env bash
# Compile and benchmark one DALO MACHINE using actual DIRECT and FIFO paths.
# Parameters: $1 mode (direct|fifo); $2 message count; $3 payload size;
# $4 number of FIFO producers (1..4); $5 optional precompiled MACHINE path.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MODE="${1:-direct}" COUNT="${2:-64}" SIZE="${3:-16}" PRODUCERS="${4:-1}"
[[ "$MODE" == direct || "$MODE" == fifo ]] || { echo 'mode must be direct or fifo' >&2; exit 64; }
[[ "$COUNT" =~ ^[1-9][0-9]*$ && "$SIZE" =~ ^(0|[1-9][0-9]*)$ && "$PRODUCERS" =~ ^[1-4]$ ]] || exit 64
((COUNT<=100000 && SIZE<=65536)) || exit 64
[[ "$MODE" != direct || "$PRODUCERS" == 1 ]] || { echo "DIRECT producer scaling is not implemented yet" >&2; exit 64; }
IMAGE="${5:-$HERE/dalo_full_benchmark.dalo.bash}"
if [[ ! -f "$IMAGE" ]]; then bash "$ROOT/compiler/daloc.bash" "$HERE/benchmark.dalo"; fi
source "$IMAGE"
DALO_BENCH_ORIGIN_NS='' DALO_BENCH_PIPE_NS='' DALO_BENCH_ENDPOINT_NS=''
for name_var in $(compgen -A variable); do
    [[ "$name_var" == *_OBJECT_NAME ]] || continue
    case "${!name_var:-}" in
        origin) DALO_BENCH_ORIGIN_NS="${name_var%_OBJECT_NAME}" ;;
        pipe) DALO_BENCH_PIPE_NS="${name_var%_OBJECT_NAME}" ;;
        endpoint) DALO_BENCH_ENDPOINT_NS="${name_var%_OBJECT_NAME}" ;;
    esac
done
[[ -n "$DALO_BENCH_ORIGIN_NS" && -n "$DALO_BENCH_PIPE_NS" && -n "$DALO_BENCH_ENDPOINT_NS" ]] || exit 70
printf -v DALO_BENCH_PAYLOAD '%*s' "$SIZE" ''
DALO_BENCH_PAYLOAD="${DALO_BENCH_PAYLOAD// /x}"
DALO_BENCH_SIZE="$SIZE" DALO_BENCH_RECEIVED=0 DALO_BENCH_BYTES=0 DALO_BENCH_DUPLICATES=0
declare -A DALO_BENCH_SEEN=()
# Bash EPOCHREALTIME avoids a per-message external timer process.
start="${EPOCHREALTIME:?Bash 5 required}"
if [[ "$MODE" == direct ]]; then
    # DIRECT invokes the generated worker in this MACHINE process.
    for ((i=1;i<=COUNT;i++)); do
        "${DALO_BENCH_ORIGIN_NS}_summon_worker" out "$i|$DALO_BENCH_PAYLOAD"
    done
else
    # FIFO producers inherit the compiled origin's persistent write descriptor.
    # The parent remains the sole dispatcher and owner of endpoint counters.
    pids=()
    for ((lane=0;lane<PRODUCERS;lane++)); do
        (
            for ((i=lane+1;i<=COUNT;i+=PRODUCERS)); do
                "${DALO_BENCH_ORIGIN_NS}_fifo_send" P origin pipe "$i|$DALO_BENCH_PAYLOAD" || exit
            done
        ) & pids+=("$!")
    done
    deadline=$((SECONDS+30+COUNT/50))
    while ((DALO_BENCH_RECEIVED<COUNT && SECONDS<deadline)); do
        "${DALO_BENCH_ORIGIN_NS}_drain_fifo" || exit
        # Yield only if no messages were available; this is not timed latency.
    done
    for pid in "${pids[@]}"; do wait "$pid" || exit; done
    "${DALO_BENCH_ORIGIN_NS}_drain_fifo"
fi
end="${EPOCHREALTIME:?}"
((DALO_BENCH_RECEIVED==COUNT && DALO_BENCH_BYTES==COUNT*SIZE && DALO_BENCH_DUPLICATES==0)) || {
    printf 'FAIL received=%d expected=%d bytes=%d duplicates=%d
' "$DALO_BENCH_RECEIVED" "$COUNT" "$DALO_BENCH_BYTES" "$DALO_BENCH_DUPLICATES" >&2
    exit 1
}
# Use a single Python invocation after the timed region for numeric formatting.
python3 - "$start" "$end" "$MODE" "$COUNT" "$SIZE" "$PRODUCERS" <<'PYINNER'
import sys
start,end=map(float,sys.argv[1:3]); mode=sys.argv[3]; count,size,producers=map(int,sys.argv[4:7])
seconds=end-start
print(f'PASS mode={mode} producers={producers} unique={count} bytes={count*size} duplicates=0 seconds={seconds:.6f} msgps={count/seconds:.3f}')
PYINNER
