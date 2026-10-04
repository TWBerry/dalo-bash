#!/usr/bin/env bash
# Opt-in credit ownership for one asynchronous DALO output sender.
# Source queue-credit.bashlib.sh and queue-credit-ack.bashlib.sh first.

# Initialize the sender's private ACK channel and authoritative credit ledger.
# Parameters: $1 private FIFO path; $2 unique sender generation; $3 budget bytes.
dalo_sender_credit_init() {
    (($# == 3)) || return 2
    local fifo="$1" instance="$2" budget="$3"
    [[ "$instance" =~ ^[A-Za-z0-9_.:-]+$ && ${#instance} -le 64 ]] || return 2
    [[ ! -e "$fifo" ]] || return 76
    mkfifo -m 600 -- "$fifo" || return
    DALO_SENDER_ACK_FIFO="$fifo"
    DALO_SENDER_INSTANCE="$instance"
    DALO_SENDER_NEXT_ID=0
    dalo_credit_init "$budget" "$instance" || return
    dalo_credit_ack_open_sender "$fifo" DALO_SENDER_ACK_FD || return
}

# Reserve one vector and register it on the existing data FIFO before O/C.
# Parameters: $1 logical slot|port key; $2 exact payload bytes.
# The caller supplies DALO_SENDER_FRAME_SEND, a function accepting R fields.
dalo_sender_credit_register() {
    (($# == 2)) || return 2
    local key="$1" bytes="$2" id rc
    [[ "$key" =~ ^[0-9]+\|[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 2
    declare -F "${DALO_SENDER_FRAME_SEND:-}" >/dev/null || return 94
    id="$((++DALO_SENDER_NEXT_ID))"
    # The v1 sender serializes vectors: wait for the previous parent ACK
    # before reusing slot|port, preventing ambiguous parent registrations.
    while :; do
        if dalo_credit_reserve "$id" "$bytes"; then break; else rc=$?; fi
        ((rc == 75)) || return "$rc"
        dalo_credit_ack_receive "$DALO_SENDER_ACK_FD" "${DALO_SENDER_ACK_TIMEOUT:-30}" || return
    done
    if ! "$DALO_SENDER_FRAME_SEND" R "$key" "$DALO_SENDER_ACK_FIFO" "$DALO_SENDER_INSTANCE" "$id" "$bytes"; then
        # Transport failure is fatal: the caller must stop this generation.
        return 92
    fi
    DALO_SENDER_LAST_ID="$id"
}

# Wait for the last vector's exact ACK before sender completion is reported.
# Parameters: none; uses the sender-owned private FIFO and outstanding ID.
dalo_sender_credit_finish() {
    # ACKs can be outstanding for earlier vectors even after the final ID
    # is acknowledged. Drain the entire ledger, never only the final ID.
    # The caller must keep the parent dispatcher alive while this waits.
    local received=0
    while ((DALO_CREDIT_USED > 0)); do
        ((received < ${DALO_SENDER_ACK_MAX_FRAMES:-4096})) || return 78
        dalo_credit_ack_receive "$DALO_SENDER_ACK_FD" "${DALO_SENDER_ACK_TIMEOUT:-30}" || return
        received=$((received + 1))
    done
}

# Close and unlink a sender-owned private ACK channel after sender exit.
# Parameters: none; the caller must ensure no further parent ACK writes.
dalo_sender_credit_close() {
    if [[ -n ${DALO_SENDER_ACK_FD:-} ]]; then
        exec {DALO_SENDER_ACK_FD}>&- || return
    fi
    [[ -z ${DALO_SENDER_ACK_FIFO:-} ]] || rm -f -- "$DALO_SENDER_ACK_FIFO"
}
