#!/usr/bin/env bash
# Experimental parent-to-sender ACK transport for the DALO credit ledger.
# This module does not modify the generated MACHINE FIFO dispatcher.

# Open an existing per-sender ACK FIFO for reading without blocking startup.
# Parameters: $1 path of the private FIFO; $2 output variable for the FD.
# A read/write open prevents startup from waiting for a parent writer; the
# sender must still enforce an ACK deadline and check parent liveness.
dalo_credit_ack_open_sender() {
    (($# == 2)) || return 2
    local fifo_path="$1" fd_var="$2" allocated_fd
    [[ -p "$fifo_path" && "$fd_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    exec {allocated_fd}<>"$fifo_path" || return
    printf -v "$fd_var" '%s' "$allocated_fd"
}

# Write one bounded ACK frame to the private FIFO after complete reception.
# Parameters: $1 ACK FIFO path; $2 instance; $3 message ID; $4 payload bytes.
# Instance and message identifiers are restricted to ASCII tokens so the
# newline-delimited frame cannot be split or forged with embedded separators.
dalo_credit_ack_send() {
    (($# == 4)) || return 2
    local fifo_path="$1" instance="$2" id="$3" bytes="$4"
    [[ -p "$fifo_path" && "$instance" =~ ^[A-Za-z0-9_.:-]+$ &&
       "$id" =~ ^[A-Za-z0-9_.:-]+$ && "$bytes" =~ ^(0|[1-9][0-9]*)$ &&
       ${#instance} -le 64 && ${#id} -le 64 && ${#bytes} -le 8 ]] || return 2
    # The caller must already have a live FIFO reader. A timeout/health check
    # belongs to the parent dispatcher; this write is intentionally atomic.
    printf 'A\t%s\t%s\t%s\n' "$instance" "$id" "$bytes" >"$fifo_path"
}

# Consume one complete ACK from the sender's private FIFO and update credit.
# Parameters: $1 open sender FD; $2 timeout in seconds (integer >= 1).
# Returns: 78 for timeout, 77 for malformed/stale/duplicate ACK, or the
# credit-ledger error. No capacity is released before exact ACK validation.
dalo_credit_ack_receive() {
    (($# == 2)) || return 2
    local ack_fd="$1" timeout="$2" line tag instance id bytes extra
    [[ "$ack_fd" =~ ^[0-9]+$ && "$timeout" =~ ^[1-9][0-9]*$ ]] || return 2
    IFS= read -r -t "$timeout" -u "$ack_fd" line || return 78
    IFS=$'\t' read -r tag instance id bytes extra <<< "$line"
    [[ "$tag" == A && -z "$extra" && "$instance" =~ ^[A-Za-z0-9_.:-]+$ &&
       "$id" =~ ^[A-Za-z0-9_.:-]+$ && "$bytes" =~ ^(0|[1-9][0-9]*)$ &&
       ${#instance} -le 64 && ${#id} -le 64 && ${#bytes} -le 8 ]] || return 77
    dalo_credit_ack "$instance" "$id" "$bytes"
}

# Wait for one exact outstanding message to be acknowledged. Unrelated valid
# ACKs may release their own reservations while this message remains pending.
# Parameters: $1 sender FD; $2 message ID; $3 maximum ACK frames to read;
# $4 timeout in seconds for each read. The caller owns the global deadline.
dalo_credit_ack_wait_id() {
    (($# == 4)) || return 2
    local ack_fd="$1" id="$2" max_frames="$3" timeout="$4" i
    [[ "$id" =~ ^[A-Za-z0-9_.:-]+$ && "$max_frames" =~ ^[1-9][0-9]*$ ]] || return 2
    [[ -v DALO_CREDIT_PENDING["$id"] ]] || return 77
    for ((i=0; i<max_frames; i++)); do
        dalo_credit_ack_receive "$ack_fd" "$timeout" || return $?
        [[ -v DALO_CREDIT_PENDING["$id"] ]] || return 0
    done
    return 78
}
