# Relay a validated child FIFO frame into the target OBJECT's public DATA input.
# Parameters: $1 source OBJECT name; $2 target OBJECT name; $3 opaque payload.
# The generated MACHINE validates both identities before calling this handler.
# This benchmark handler permits only the PIPE -> ENDPOINT edge.
[[ "$1" == pipe && "$2" == endpoint ]] || return 76
[[ -n "${DALO_BENCH_ENDPOINT_NS:-}" ]] || return 77
"${DALO_BENCH_ENDPOINT_NS}_summon_worker" in "$3"
