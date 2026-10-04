#!/usr/bin/env bash
# Benchmark one compiled MACHINE with real persistent ENDPOINT worker processes.
# Parameters: $1 transport (direct|fifo); $2 messages; $3 payload bytes;
# $4 endpoint process count (1..4); $5 FIFO producer count (1..4, default 1);
# $6 PIPE process count (1..4, default 1).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MODE="${1:-direct}" COUNT="${2:-256}" SIZE="${3:-16}" WORKERS="${4:-1}" PRODUCERS="${5:-1}" PIPE_WORKERS="${6:-1}"
[[ "$MODE" == direct || "$MODE" == fifo ]] || exit 64
[[ "$COUNT" =~ ^[1-9][0-9]*$ && "$SIZE" =~ ^(0|[1-9][0-9]*)$ && "$WORKERS" =~ ^[1-4]$ && "$PRODUCERS" =~ ^[1-4]$ && "$PIPE_WORKERS" =~ ^[1-4]$ ]] || exit 64
((COUNT<=100000 && SIZE<=65536)) || exit 64
[[ "$MODE" != direct || "$PRODUCERS" == 1 ]] || exit 64
IMAGE="$HERE/dalo_full_benchmark.dalo.bash"
if [[ ! -f "$IMAGE" || "$HERE/pipe.bash" -nt "$IMAGE" || "$HERE/benchmark.dalo" -nt "$IMAGE" ]]; then
    bash "$ROOT/compiler/daloc.bash" "$HERE/benchmark.dalo" >/dev/null
fi
source "$HERE/../scheduler/process-pool.bash"
source "$HERE/endpoint-pool.bash"
source "$HERE/pipe-pool.bash"
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
dalo_bench_endpoint_start "$WORKERS" "$HERE/../scheduler/process-worker.bash"
DALO_BENCH_PIPE_IMAGE="$IMAGE"
dalo_bench_pipe_start "$PIPE_WORKERS" "$HERE/pipe-process-worker.bash"
trap 'dalo_bench_pipe_pool_stop 2>/dev/null || :; dalo_bench_pool_stop 2>/dev/null || :' EXIT
start="${EPOCHREALTIME:?Bash 5 required}"
if [[ "$MODE" == direct ]]; then
    for ((i=1;i<=COUNT;i++)); do
        "${DALO_BENCH_ORIGIN_NS}_summon_worker" out "$i|$DALO_BENCH_PAYLOAD"
    done
else
    pids=()
    for ((lane=0;lane<PRODUCERS;lane++)); do
        (
            for ((i=lane+1;i<=COUNT;i+=PRODUCERS)); do
                "${DALO_BENCH_ORIGIN_NS}_fifo_send" P origin pipe "$i|$DALO_BENCH_PAYLOAD" || exit
            done
        ) & pids+=("$!")
    done
    deadline=$((SECONDS+30+COUNT/50))
    while ((DALO_BENCH_RECEIVED+DALO_BENCH_ENDPOINT_PENDING+DALO_BENCH_PIPE_PENDING<COUNT && SECONDS<deadline)); do
        "${DALO_BENCH_ORIGIN_NS}_drain_fifo" || exit
    done
    for pid in "${pids[@]}"; do wait "$pid" || exit; done
    "${DALO_BENCH_ORIGIN_NS}_drain_fifo"
fi
dalo_bench_pipe_flush
dalo_bench_endpoint_flush
end="${EPOCHREALTIME:?}"
((DALO_BENCH_RECEIVED==COUNT && DALO_BENCH_BYTES==COUNT*SIZE && DALO_BENCH_DUPLICATES==0)) || {
    printf 'FAIL received=%d expected=%d bytes=%d duplicates=%d\n' "$DALO_BENCH_RECEIVED" "$COUNT" "$DALO_BENCH_BYTES" "$DALO_BENCH_DUPLICATES" >&2
    exit 1
}
for ((lane=0;lane<PIPE_WORKERS;lane++)); do
    [[ "${DALO_BENCH_PIPE_POOL_SENT[lane]}" == "${DALO_BENCH_PIPE_POOL_RECEIVED[lane]}" ]] || exit 78
    kill -0 "${DALO_BENCH_PIPE_POOL_PIDS[lane]}" || exit 79
done
for ((lane=0;lane<WORKERS;lane++)); do
    [[ "${DALO_BENCH_POOL_SENT[lane]}" == "${DALO_BENCH_POOL_RECEIVED[lane]}" ]] || exit 78
    kill -0 "${DALO_BENCH_POOL_PIDS[lane]}" || exit 79
done
python3 - "$start" "$end" "$MODE" "$COUNT" "$SIZE" "$WORKERS" "$PRODUCERS" "$PIPE_WORKERS" <<'PYINNER'
import sys
start,end=map(float,sys.argv[1:3]); mode=sys.argv[3]
count,size,workers,producers,pipe_workers=map(int,sys.argv[4:9]); seconds=end-start
print(f'PASS mode={mode} endpoint_workers={workers} pipe_workers={pipe_workers} producers={producers} unique={count} bytes={count*size} duplicates=0 seconds={seconds:.6f} msgps={count/seconds:.3f}')
PYINNER
