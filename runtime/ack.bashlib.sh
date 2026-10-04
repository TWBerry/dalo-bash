#!/usr/bin/env bash
# Generic DALO in-process ACK bookkeeping ABI v1. This library does not own transport.
DALO_LIBRARY_NAME="ack"
DALO_LIBRARY_ABI=1
DALO_LIBRARY_REQUIRES=""
DALO_LIBRARY_INIT="dalo_ack_init"
DALO_LIBRARY_FINI="dalo_ack_shutdown"

# Initialize request and endpoint deduplication tables in the current process.
# Parameters: none. Must be called by the generic library loader.
dalo_ack_init() {
    declare -gA DALO_ACK_PENDING=() DALO_ACK_APPLIED=() DALO_ACK_RECEIPT=()
    declare -g DALO_ACK_INSTANCE="${BASHPID}:${EPOCHREALTIME:-0}"
}

# Validate an opaque identity component used in a compound ACK key.
# Parameters: $1 nonempty component containing only ASCII letters, digits, dot, underscore or hyphen.
dalo_ack_valid_part() {
    [[ $# -eq 1 && "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

# Build a collision-free compound key into a caller-provided variable.
# Parameters: $1 output variable; $2 instance; $3 client; $4 request ID.
dalo_ack_key() {
    [[ $# -eq 4 && "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    dalo_ack_valid_part "$2" && dalo_ack_valid_part "$3" && dalo_ack_valid_part "$4" || return 2
    printf -v "$1" '%s:%s:%s' "$2" "$3" "$4"
}

# Register one outgoing request, rejecting reuse of a still-pending identity.
# Parameters: $1 instance; $2 client; $3 request ID. Returns 3 for duplicate pending ID.
dalo_ack_register() {
    local key
    dalo_ack_key key "$1" "$2" "$3" || return
    [[ ! -v DALO_ACK_PENDING[$key] ]] || return 3
    DALO_ACK_PENDING["$key"]=pending
}

# Accept an ACK only when its exact instance/client/request tuple is pending.
# Parameters: $1 instance; $2 client; $3 request ID. Returns 4 for stale or duplicate ACK.
dalo_ack_confirm() {
    local key
    dalo_ack_key key "$1" "$2" "$3" || return
    [[ "${DALO_ACK_PENDING[$key]-}" == pending ]] || return 4
    DALO_ACK_PENDING["$key"]=confirmed
}

# Record one accepted endpoint request and identify replay without reapplying data.
# Parameters: $1 instance; $2 client; $3 request ID; $4 payload fingerprint.
# Returns 0 for first delivery, 10 for identical replay, 11 for conflicting replay.
dalo_ack_endpoint_accept() {
    [[ $# -eq 4 && -n "$4" ]] || return 2
    local key
    dalo_ack_key key "$1" "$2" "$3" || return
    if [[ -v DALO_ACK_APPLIED[$key] ]]; then
        [[ "${DALO_ACK_APPLIED[$key]}" == "$4" ]] && return 10
        return 11
    fi
    DALO_ACK_APPLIED["$key"]="$4"
}

# Release completed outgoing requests and their ACK tombstones after a bounded session.
# Parameters: $1 instance; $2 client; $3 request ID. Returns 5 if not yet confirmed.
dalo_ack_release() {
    local key
    dalo_ack_key key "$1" "$2" "$3" || return
    [[ "${DALO_ACK_PENDING[$key]-}" == confirmed ]] || return 5
    unset 'DALO_ACK_PENDING[$key]'
}

# Forget all endpoint deduplication records belonging to an explicitly closed instance.
# Parameters: $1 instance. Call only when no retries from this instance can arrive.
dalo_ack_close_instance() {
    [[ $# -eq 1 ]] && dalo_ack_valid_part "$1" || return 2
    local key
    for key in "${!DALO_ACK_APPLIED[@]}"; do
        [[ "$key" == "$1":* ]] && unset 'DALO_ACK_APPLIED[$key]'
    done
}

# Clean up ACK bookkeeping on MACHINE shutdown, after workers have stopped.
# Parameters: none.
dalo_ack_shutdown() {
    DALO_ACK_PENDING=() DALO_ACK_APPLIED=() DALO_ACK_RECEIPT=()
}

# Cancel every outstanding request owned by one worker/client in one instance.
# Parameters: $1 instance identity; $2 client identity.
# Returns the number of cancelled requests in DALO_ACK_CANCELLED_COUNT.
# This removes outgoing request state only; endpoint deduplication remains until
# the entire instance is explicitly closed after all retries have ceased.
dalo_ack_cancel_client() {
    (( $# == 2 )) || return 2
    dalo_ack_valid_part "$1" && dalo_ack_valid_part "$2" || return 2
    local key prefix="$1:$2:"
    DALO_ACK_CANCELLED_COUNT=0
    for key in "${!DALO_ACK_PENDING[@]}"; do
        [[ "$key" == "$prefix"* ]] || continue
        unset 'DALO_ACK_PENDING[$key]'
        ((DALO_ACK_CANCELLED_COUNT+=1))
    done
}
