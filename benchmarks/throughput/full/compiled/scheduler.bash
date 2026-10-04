#!/usr/bin/env bash
# Dispatch a child-originated frame through compiled PIPE and ENDPOINT workers.
# Parameters: $1 source object; $2 destination object; $3 sequence|payload frame.
[[ "$1" == origin && "$2" == pipe ]] || return 76
"${DALO_BENCH_PIPE_NS}_summon_worker" in "$3"
