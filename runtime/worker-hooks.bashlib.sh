#!/usr/bin/env bash
# Generic per-WORKER pre-stop hooks; no knowledge of ACK or benchmark objects.
DALO_LIBRARY_NAME="worker-hooks"
DALO_LIBRARY_ABI=1
DALO_LIBRARY_REQUIRES=""
DALO_LIBRARY_INIT="dalo_worker_hooks_init"
DALO_LIBRARY_FINI="dalo_worker_hooks_fini"

# Initialize per-WORKER callback registration and once-only stop state.
# Parameters: none.
dalo_worker_hooks_init() {
    declare -ga DALO_WORKER_STOP_HOOK_WORKERS=() DALO_WORKER_STOP_HOOK_FUNCTIONS=() DALO_WORKER_STOP_HOOK_ARGUMENTS=()
    declare -gA DALO_WORKER_STOP_NOTIFIED=()
    declare -gA DALO_CHILD_REAP_CALLBACK=() DALO_CHILD_REAP_ARGUMENTS=() DALO_CHILD_REAP_NOTIFIED=()
}

# Register a callback for a WORKER namespace before its stop handler runs.
# Parameters: $1 WORKER namespace; $2 callback function; $3+ callback arguments.
# Arguments are serialized using Bash %q, then restored as a positional array.
dalo_worker_stop_hook_add() {
    (( $# >= 2 )) || return 2
    local worker="$1" callback="$2" encoded="" arg
    [[ "$worker" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    declare -F "$callback" >/dev/null || return 3
    [[ ! -v DALO_WORKER_STOP_NOTIFIED[$worker] ]] || return 4
    shift 2
    printf -v encoded '%q ' "$@"
    DALO_WORKER_STOP_HOOK_WORKERS+=("$worker")
    DALO_WORKER_STOP_HOOK_FUNCTIONS+=("$callback")
    DALO_WORKER_STOP_HOOK_ARGUMENTS+=("$encoded")
}

# Notify all registered callbacks for one WORKER, at most once.
# Parameters: $1 WORKER namespace. Failures are collected without skipping hooks.
dalo_worker_stop_notify() {
    (( $# == 1 )) || return 2
    local worker="$1" i rc=0 result=0
    [[ "$worker" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [[ ! -v DALO_WORKER_STOP_NOTIFIED[$worker] ]] || return 0
    DALO_WORKER_STOP_NOTIFIED["$worker"]=1
    for ((i=0; i<${#DALO_WORKER_STOP_HOOK_WORKERS[@]}; i++)); do
        [[ "${DALO_WORKER_STOP_HOOK_WORKERS[i]}" == "$worker" ]] || continue
        local -a args=()
        # This string contains only shell-escaped arguments emitted by printf %q.
        eval "args=( ${DALO_WORKER_STOP_HOOK_ARGUMENTS[i]} )"
        "${DALO_WORKER_STOP_HOOK_FUNCTIONS[i]}" "${args[@]}" || { result=$?; ((rc == 0)) && rc=$result; }
    done
    return "$rc"
}

# Release hook registrations during generic library FINI.
# Parameters: none.
dalo_worker_hooks_fini() {
    DALO_WORKER_STOP_HOOK_WORKERS=() DALO_WORKER_STOP_HOOK_FUNCTIONS=() DALO_WORKER_STOP_HOOK_ARGUMENTS=()
    DALO_WORKER_STOP_NOTIFIED=()
    DALO_CHILD_REAP_CALLBACK=() DALO_CHILD_REAP_ARGUMENTS=() DALO_CHILD_REAP_NOTIFIED=()
}

# Register one parent-owned callback for a specific live child PID.
# Parameters: $1 positive child PID; $2 callback function; $3+ callback arguments.
# The caller must register the PID before reaping and must not reuse a PID
# registration after the corresponding child has been reaped.
dalo_child_reap_hook_add() {
    (( $# >= 2 )) || return 2
    local pid="$1" callback="$2" encoded
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$callback" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    declare -F "$callback" >/dev/null || return 3
    [[ ! -v DALO_CHILD_REAP_CALLBACK[$pid] && ! -v DALO_CHILD_REAP_NOTIFIED[$pid] ]] || return 4
    shift 2
    printf -v encoded '%q ' "$@"
    DALO_CHILD_REAP_CALLBACK["$pid"]="$callback"
    DALO_CHILD_REAP_ARGUMENTS["$pid"]="$encoded"
}

# Notify and forget the registered callback after the parent reaps a child.
# Parameters: $1 child PID; $2 wait exit status; $3 pool namespace; $4 slot ID.
# A callback is invoked at most once, before the pool can recycle the slot.
dalo_child_reap_notify() {
    (( $# == 4 )) || return 2
    local pid="$1" rc="$2" pool="$3" slot="$4" callback
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$rc" =~ ^[0-9]+$ && "$pool" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$slot" =~ ^[0-9]+$ ]] || return 2
    [[ ! -v DALO_CHILD_REAP_NOTIFIED[$pid] ]] || return 0
    callback="${DALO_CHILD_REAP_CALLBACK[$pid]-}"
    [[ -n "$callback" ]] || return 0
    local -a args=()
    eval "args=( ${DALO_CHILD_REAP_ARGUMENTS[$pid]} )"
    DALO_CHILD_REAP_NOTIFIED["$pid"]=1
    unset 'DALO_CHILD_REAP_CALLBACK[$pid]' 'DALO_CHILD_REAP_ARGUMENTS[$pid]'
    "$callback" "$pid" "$rc" "$pool" "$slot" "${args[@]}"
}
