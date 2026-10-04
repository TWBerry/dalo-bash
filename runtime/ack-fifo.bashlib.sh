#!/usr/bin/env bash
# Generic FIFO ACK adapter. Transport ownership remains with the MACHINE dispatcher.
DALO_LIBRARY_NAME="ack-fifo"
DALO_LIBRARY_ABI=1
DALO_LIBRARY_REQUIRES="ack worker-hooks"
DALO_LIBRARY_INIT=""
DALO_LIBRARY_FINI=""

# Register and send a request using a caller-provided transport function.
# Parameters: $1 instance; $2 client; $3 request ID; $4 transport function; $5+ transport arguments.
dalo_ack_fifo_send() {
    (( $# >= 5 )) || return 2
    local instance="$1" client="$2" request="$3" sender="$4"
    shift 4
    dalo_ack_register "$instance" "$client" "$request" || return
    "$sender" "$@"
}

# Confirm one incoming ACK frame for the exact pending request.
# Parameters: $1 expected instance; $2 expected client; $3 ACK|instance|client|request frame.
dalo_ack_fifo_receive() {
    (( $# == 3 )) || return 2
    local expected_instance="$1" expected_client="$2" frame="$3" instance client request
    [[ "$frame" =~ ^ACK\|([A-Za-z0-9_.-]+)\|([A-Za-z0-9_.-]+)\|([A-Za-z0-9_.-]+)$ ]] || return 2
    instance="${BASH_REMATCH[1]}" client="${BASH_REMATCH[2]}" request="${BASH_REMATCH[3]}"
    [[ "$instance" == "$expected_instance" && "$client" == "$expected_client" ]] || return 4
    dalo_ack_confirm "$instance" "$client" "$request"
}

# Validate and deduplicate a request before invoking the endpoint callback.
# Parameters: $1 instance; $2 client; $3 request ID; $4 fingerprint; $5 callback; $6+ callback arguments.
# Returns 0 for newly applied, 10 for replay, 11 for conflicting payload.
dalo_ack_fifo_deliver() {
    (( $# >= 6 )) || return 2
    local instance="$1" client="$2" request="$3" fingerprint="$4" callback="$5" rc key
    shift 5
    dalo_ack_endpoint_accept "$instance" "$client" "$request" "$fingerprint"; rc=$?
    (( rc == 0 )) || return "$rc"
    if ! "$callback" "$@"; then
        # Roll back the provisional receipt. The callback must be atomic or idempotent.
        dalo_ack_key key "$instance" "$client" "$request" || return
        unset 'DALO_ACK_APPLIED[$key]'
        return 12
    fi
}

# Retransmit an existing pending request without allocating a second identity.
# Parameters: $1 instance; $2 client; $3 request ID; $4 transport function; $5+ transport arguments.
dalo_ack_fifo_retry() {
    (( $# >= 5 )) || return 2
    local key instance="$1" client="$2" request="$3" sender="$4"
    shift 4
    dalo_ack_key key "$instance" "$client" "$request" || return
    [[ "${DALO_ACK_PENDING[$key]-}" == pending ]] || return 5
    "$sender" "$@"
}

# Wait for a set of pending ACKs and retransmit only requests still outstanding.
# Parameters: $1 instance; $2 client; $3 ACK read FD; $4 timeout seconds;
# $5 maximum retry rounds; $6 name of caller's associative pending-ID array;
# $7 retransmit callback (called with request ID); $8+ callback arguments.
# Returns 0 when all ACKs arrive, 90 on exhausted retries, 91 for a malformed
# ACK, 92 for an unexpected/stale ACK, 93 for a cancelled worker, or the
# callback's nonzero return code. Cancellation is opt-in via the process-local
# DALO_ACK_FIFO_CANCELLED flag, set by the worker's signal/teardown handler.
# The caller owns its transport, pending array and FD; this function owns the
# bounded ACK/retry loop and never closes descriptors belonging to the caller.
dalo_ack_fifo_wait_pending() {
    (( $# >= 7 )) || return 2
    local instance="$1" client="$2" fd="$3" timeout="$4" max_retries="$5"
    local pending_name="$6" resend="$7" line ack_instance ack_client ack_id id rounds=0
    shift 7
    [[ "$fd" =~ ^[0-9]+$ && "$max_retries" =~ ^[0-9]+$ ]] || return 2
    [[ "$pending_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    local -n outstanding="$pending_name"
    while ((${#outstanding[@]})); do
        if [[ "${DALO_ACK_FIFO_CANCELLED:-0}" == 1 ]]; then
            dalo_ack_cancel_client "$instance" "$client" || return
            outstanding=()
            return 93
        fi
        if IFS= read -r -t "$timeout" -u "$fd" line; then
            if [[ "${DALO_ACK_FIFO_CANCELLED:-0}" == 1 ]]; then
                dalo_ack_cancel_client "$instance" "$client" || return
                outstanding=()
                return 93
            fi
            [[ "$line" =~ ^ACK\|([A-Za-z0-9_.-]+)\|([A-Za-z0-9_.-]+)\|([A-Za-z0-9_.-]+)$ ]] || return 91
            ack_instance="${BASH_REMATCH[1]}" ack_client="${BASH_REMATCH[2]}" ack_id="${BASH_REMATCH[3]}"
            [[ "$ack_instance" == "$instance" && "$ack_client" == "$client" && -v outstanding[$ack_id] ]] || return 92
            dalo_ack_fifo_receive "$instance" "$client" "$line" || return 92
            dalo_ack_release "$instance" "$client" "$ack_id" || return 92
            unset 'outstanding[$ack_id]'
            continue
        fi
        if [[ "${DALO_ACK_FIFO_CANCELLED:-0}" == 1 ]]; then
            dalo_ack_cancel_client "$instance" "$client" || return
            outstanding=()
            return 93
        fi
        (( rounds < max_retries )) || return 90
        ((rounds+=1))
        for id in "${!outstanding[@]}"; do
            if [[ "${DALO_ACK_FIFO_CANCELLED:-0}" == 1 ]]; then
                dalo_ack_cancel_client "$instance" "$client" || return
                outstanding=()
                return 93
            fi
            "$resend" "$id" "$@" || return
        done
    done
    DALO_ACK_FIFO_RETRY_ROUNDS="$rounds"
}

# Bind one ACK client to a generated WORKER's lifecycle stop notification.
# Parameters: $1 generated WORKER namespace; $2 instance; $3 client.
# This is an opt-in binding; unbound workers retain their existing behavior.
dalo_ack_fifo_bind_worker() {
    (( $# == 3 )) || return 2
    dalo_ack_valid_part "$2" && dalo_ack_valid_part "$3" || return 2
    dalo_worker_stop_hook_add "$1" dalo_ack_fifo_worker_stop "$2" "$3"
}

# Cancel a bound client's outgoing requests when its WORKER is stopped.
# Parameters: $1 instance; $2 client. Endpoint receipts remain untouched.
dalo_ack_fifo_worker_stop() {
    (( $# == 2 )) || return 2
    dalo_ack_cancel_client "$1" "$2"
}

# Bind a parent-owned ACK client to a particular child PID's reap event.
# Parameters: $1 child PID; $2 ACK instance; $3 ACK client.
# Register in the parent immediately after spawning a child, before reaping.
dalo_ack_fifo_bind_child_pid() {
    (( $# == 3 )) || return 2
    dalo_ack_valid_part "$2" && dalo_ack_valid_part "$3" || return 2
    dalo_child_reap_hook_add "$1" dalo_ack_fifo_child_reaped "$2" "$3"
}

# Cancel parent-owned outgoing ACK state for a child that has been reaped.
# Parameters: $1 PID; $2 wait status; $3 pool namespace; $4 slot ID;
# $5 ACK instance; $6 ACK client. Endpoint dedup receipts are preserved.
dalo_ack_fifo_child_reaped() {
    (( $# == 6 )) || return 2
    dalo_ack_cancel_client "$5" "$6"
}
