#!/usr/bin/env bash
worker() {
    local worker_dir="$1" slot_id="$2"; shift 2
    : "$worker_dir" "$slot_id"
    printf '%s\n' "$*"
}
