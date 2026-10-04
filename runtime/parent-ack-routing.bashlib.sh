#!/usr/bin/env bash
# Parent-owned routing of completed output vectors to private sender ACK FIFOs.
# Load this library in the owning MACHINE parent and configure
# DALO_CREDIT_PARENT_ACK_HOOK=dalo_parent_ack_complete.

# Initialize the parent-owned table of output-to-sender ACK registrations.
# Parameters: none. Call once before admitting any worker output.
dalo_parent_ack_init() {
    declare -gA DALO_PARENT_ACK_FIFO=()
    declare -gA DALO_PARENT_ACK_INSTANCE=()
    declare -gA DALO_PARENT_ACK_ID=()
    declare -gA DALO_PARENT_ACK_BYTES=()
}

# Register an expected complete output vector before dispatching the sender.
# Parameters: $1 logical output key (slot|port); $2 private ACK FIFO path;
# $3 sender instance/generation; $4 unique message ID; $5 payload byte count.
# Returns 76 on duplicate key and 2 on invalid input.
dalo_parent_ack_register() {
    (($# == 5)) || return 2
    local key="$1" fifo="$2" instance="$3" id="$4" bytes="$5"
    [[ "$key" =~ ^[0-9]+\|[A-Za-z_][A-Za-z0-9_.-]*$ && -p "$fifo" &&
       "$instance" =~ ^[A-Za-z0-9_.:-]+$ && "$id" =~ ^[A-Za-z0-9_.:-]+$ &&
       "$bytes" =~ ^(0|[1-9][0-9]*)$ && ${#bytes} -le 8 &&
       ${#instance} -le 64 && ${#id} -le 64 ]] || return 2
    [[ ! -v DALO_PARENT_ACK_FIFO["$key"] ]] || return 76
    DALO_PARENT_ACK_FIFO["$key"]="$fifo"
    DALO_PARENT_ACK_INSTANCE["$key"]="$instance"
    DALO_PARENT_ACK_ID["$key"]="$id"
    DALO_PARENT_ACK_BYTES["$key"]="$bytes"
}

# Deliver an ACK with a bounded FIFO-open/write operation.
# Parameters: $1 FIFO path; $2 sender instance; $3 message ID; $4 byte count.
# DALO_PARENT_ACK_TIMEOUT sets the deadline in seconds (default: 2).
# A timeout returns 78 and leaves the caller's registration untouched.
dalo_parent_ack_send_bounded() {
    (($# == 4)) || return 2
    local fifo="$1" instance="$2" id="$3" bytes="$4"
    local deadline="${DALO_PARENT_ACK_TIMEOUT:-2}" rc
    [[ "$deadline" =~ ^[1-9][0-9]*$ ]] || return 2
    command -v timeout >/dev/null 2>&1 || return 94
    # The subprocess prevents a crashed sender from blocking the parent.
    # Arguments are positional, not interpolated into shell source.
    timeout -s TERM "$deadline" bash -c \
        'printf "A\t%s\t%s\t%s\n" "$2" "$3" "$4" >"$1"' \
        _ "$fifo" "$instance" "$id" "$bytes" && return 0
    rc=$?
    ((rc == 124 || rc == 137)) && return 78
    return 92
}

# Send an ACK after the runtime stores a complete output vector in its parent.
# Parameters: $1 logical output key; $2 actual complete payload byte count.
# Returns 77 for missing registration and 92 for mismatched byte count.
# Keep registration intact on write failure so the caller can fail visibly.
dalo_parent_ack_complete() {
    (($# == 2)) || return 2
    local key="$1" bytes="$2"
    [[ -v DALO_PARENT_ACK_FIFO["$key"] ]] || return 77
    [[ "$bytes" == "${DALO_PARENT_ACK_BYTES[$key]}" ]] || return 92
    dalo_parent_ack_send_bounded "${DALO_PARENT_ACK_FIFO[$key]}" \
        "${DALO_PARENT_ACK_INSTANCE[$key]}" "${DALO_PARENT_ACK_ID[$key]}" "$bytes" || return
    unset 'DALO_PARENT_ACK_FIFO[$key]' 'DALO_PARENT_ACK_INSTANCE[$key]' \
          'DALO_PARENT_ACK_ID[$key]' 'DALO_PARENT_ACK_BYTES[$key]'
}

# Cancel one registration only after its sender transport is invalidated.
# Parameters: $1 logical output key; $2 exact sender instance/generation.
# Returns 77 when the key or generation does not match.
dalo_parent_ack_cancel() {
    (($# == 2)) || return 2
    local key="$1" instance="$2"
    [[ -v DALO_PARENT_ACK_FIFO["$key"] &&
       "${DALO_PARENT_ACK_INSTANCE[$key]}" == "$instance" ]] || return 77
    unset 'DALO_PARENT_ACK_FIFO[$key]' 'DALO_PARENT_ACK_INSTANCE[$key]' \
          'DALO_PARENT_ACK_ID[$key]' 'DALO_PARENT_ACK_BYTES[$key]'
    if declare -p DALO_PARENT_ACK_FAILED >/dev/null 2>&1; then
        unset 'DALO_PARENT_ACK_FAILED[$key]'
    fi
}

# Acknowledge a complete vector if it belongs to a registered credit sender.
# Parameters: $1 logical output key; $2 complete payload byte count.
# Non-credit outputs from ORIGIN and other objects have no registration.
dalo_parent_ack_complete_optional() {
    (($# == 2)) || return 2
    [[ -v DALO_PARENT_ACK_FIFO["$1"] ]] || return 0
    dalo_parent_ack_complete "$1" "$2"
}

# Initialize parent-owned sender liveness and failure records.
# Parameters: none. Call after dalo_parent_ack_init.
dalo_parent_sender_watch_init() {
    declare -gA DALO_PARENT_SENDER_PID=()
    declare -gA DALO_PARENT_SENDER_FAILED=()
    declare -gA DALO_PARENT_ACK_FAILED=()
}

# Track one sender generation without changing its pending ACK registrations.
# Parameters: $1 sender instance/generation; $2 sender process PID.
# Returns 76 if the generation is already tracked and 2 for invalid input.
dalo_parent_sender_watch() {
    (($# == 2)) || return 2
    local instance="$1" pid="$2"
    [[ "$instance" =~ ^[A-Za-z0-9_.:-]+$ && ${#instance} -le 64 &&
       "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
    [[ ! -v DALO_PARENT_SENDER_PID["$instance"] &&
       ! -v DALO_PARENT_SENDER_FAILED["$instance"] ]] || return 76
    DALO_PARENT_SENDER_PID["$instance"]="$pid"
}

# Quarantine a confirmed failed sender generation and its pending messages.
# Parameters: $1 sender instance; $2 reason token (e.g. EXIT_92).
# This deliberately does not free credits or silently discard registrations.
# The owning worker must stop/reap the sender before calling this function.
dalo_parent_sender_fail() {
    (($# == 2)) || return 2
    local instance="$1" reason="$2" key found=0
    [[ "$instance" =~ ^[A-Za-z0-9_.:-]+$ && ${#instance} -le 64 &&
       "$reason" =~ ^[A-Za-z0-9_.:-]+$ && ${#reason} -le 64 ]] || return 2
    [[ ! -v DALO_PARENT_SENDER_FAILED["$instance"] ]] || return 76
    DALO_PARENT_SENDER_FAILED["$instance"]="$reason"
    unset 'DALO_PARENT_SENDER_PID[$instance]'
    for key in "${!DALO_PARENT_ACK_INSTANCE[@]}"; do
        if [[ "${DALO_PARENT_ACK_INSTANCE[$key]}" == "$instance" ]]; then
            DALO_PARENT_ACK_FAILED["$key"]="$instance:$reason"
            found=$((found + 1))
        fi
    done
    DALO_PARENT_SENDER_FAILURE_COUNT="$found"
}

# Report liveness without inferring that an unobserved PID has crashed.
# Parameters: $1 sender instance; $2 output variable for status.
# Status is LIVE, MISSING, FAILED, or UNKNOWN. MISSING needs explicit reap
# or parent verification before dalo_parent_sender_fail is invoked.
dalo_parent_sender_status() {
    (($# == 2)) || return 2
    local instance="$1" output="$2" pid result_status
    [[ "$output" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    if [[ -v DALO_PARENT_SENDER_FAILED["$instance"] ]]; then
        result_status=FAILED
    elif [[ -v DALO_PARENT_SENDER_PID["$instance"] ]]; then
        pid="${DALO_PARENT_SENDER_PID[$instance]}"
        if kill -0 "$pid" 2>/dev/null; then result_status=LIVE; else result_status=MISSING; fi
    else
        result_status=UNKNOWN
    fi
    printf -v "$output" '%s' "$result_status"
}

# List pending registrations quarantined for a failed sender generation.
# Parameters: $1 sender instance. Output is tab-separated key, ID, bytes.
dalo_parent_sender_pending_failed() {
    (($# == 1)) || return 2
    local instance="$1" key
    [[ -v DALO_PARENT_SENDER_FAILED["$instance"] ]] || return 77
    for key in "${!DALO_PARENT_ACK_FAILED[@]}"; do
        [[ "${DALO_PARENT_ACK_INSTANCE[$key]:-}" == "$instance" ]] || continue
        printf '%s\t%s\t%s\n' "$key" "${DALO_PARENT_ACK_ID[$key]}" "${DALO_PARENT_ACK_BYTES[$key]}"
    done
}

# Reject completion of a quarantined generation instead of sending to dead FIFO.
# Parameters: $1 logical output key; $2 actual complete payload bytes.
# Returns 79 for a quarantined sender; other results match normal completion.
dalo_parent_ack_complete_guarded() {
    (($# == 2)) || return 2
    local key="$1" instance="${DALO_PARENT_ACK_INSTANCE[$1]:-}"
    [[ -z "$instance" || ! -v DALO_PARENT_SENDER_FAILED["$instance"] ]] || return 79
    dalo_parent_ack_complete_optional "$@"
}
