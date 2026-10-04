#!/usr/bin/env bash
# DALO experimental sender-side credit ledger. This is an isolated protocol
# primitive; it does not replace the existing production FIFO dispatcher.

# Initialize a sender ledger with a bounded number of outstanding payload bytes.
# Parameters: $1 capacity in bytes; $2 sender instance identity.
dalo_credit_init() {
    (($# == 2)) || return 2
    [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 8 && -n "$2" ]] || return 2
    DALO_CREDIT_CAPACITY="$1" DALO_CREDIT_INSTANCE="$2" DALO_CREDIT_USED=0
    declare -gA DALO_CREDIT_PENDING=()
}

# Reserve capacity for a complete logical output before dispatching it.
# Parameters: $1 unique message ID; $2 payload byte length.
# Returns: 75 when capacity is exhausted, 90 for oversized messages.
dalo_credit_reserve() {
    (($# == 2)) || return 2
    local id="$1" size="$2"
    [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ && "$size" =~ ^(0|[1-9][0-9]*)$ && ${#size} -le 8 ]] || return 2
    [[ ! -v DALO_CREDIT_PENDING["$id"] ]] || return 76
    ((size <= DALO_CREDIT_CAPACITY)) || return 90
    ((DALO_CREDIT_USED + size <= DALO_CREDIT_CAPACITY)) || return 75
    DALO_CREDIT_PENDING["$id"]="$size"
    DALO_CREDIT_USED=$((DALO_CREDIT_USED + size))
}

# Apply an ACK only if it matches an outstanding message and sender instance.
# Parameters: $1 instance identity; $2 message ID; $3 exact acknowledged bytes.
# Returns: 77 for stale, duplicate, or inconsistent acknowledgments.
dalo_credit_ack() {
    (($# == 3)) || return 2
    local instance="$1" id="$2" size="$3"
    [[ "$instance" == "$DALO_CREDIT_INSTANCE" ]] || return 77
    [[ -v DALO_CREDIT_PENDING["$id"] ]] || return 77
    [[ "$size" == "${DALO_CREDIT_PENDING[$id]}" ]] || return 77
    DALO_CREDIT_USED=$((DALO_CREDIT_USED - DALO_CREDIT_PENDING[$id]))
    unset 'DALO_CREDIT_PENDING[$id]'
}

# Cancel an unacknowledged message only after the owning sender is stopped and
# the transport has been invalidated, so late ACKs cannot release newer work.
# Parameters: $1 instance identity; $2 outstanding message ID.
dalo_credit_cancel() {
    (($# == 2)) || return 2
    [[ "$1" == "$DALO_CREDIT_INSTANCE" && -v DALO_CREDIT_PENDING["$2"] ]] || return 77
    DALO_CREDIT_USED=$((DALO_CREDIT_USED - DALO_CREDIT_PENDING[$2]))
    unset 'DALO_CREDIT_PENDING[$2]'
}
