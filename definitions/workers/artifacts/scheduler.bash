#!/usr/bin/env bash
# DALO SCHEDULER worker artifact v1.
# Owns the per-MACHINE canonical resource ledger through define_scheduler_api.
worker_start() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local init_var="${ns}_SCHEDULER_WORKER_INITIALIZED"
    [[ "${!init_var:-0}" == 1 ]] && return 0

    local cpu_var="${ns}_FIELD_CPU_TOTAL" memory_var="${ns}_FIELD_MEMORY_TOTAL"
    local cpu_total="${!cpu_var:-}" memory_total="${!memory_var:-}"
    [[ "$cpu_total" =~ ^[1-9][0-9]*$ && "$memory_total" =~ ^[1-9][0-9]*$ ]] || return 64

    define_scheduler_api "$ns" || return
    define_scheduler_placement_api "$ns" || return
    define_orchestrator_api "$ns" || return
    "${ns}_orchestrator_init" || return
    "${ns}_control_route_init" || return
    "${ns}_placement_init" || return
    "${ns}_cluster_init" || return
    "${ns}_scheduler_init" "$cpu_total" "$memory_total" || return
    printf -v "$init_var" '%s' 1
}

worker_poll() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local init_var="${ns}_SCHEDULER_WORKER_INITIALIZED"
    [[ "${!init_var:-0}" == 1 ]] || return 69
    "${ns}_scheduler_diagnose" || return
    "${ns}_cluster_poll"
}

worker_stop() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local state_var="${ns}_SCHEDULER_STATE"
    printf -v "$state_var" '%s' STOPPED
    printf -v "${ns}_SCHEDULER_WORKER_INITIALIZED" '%s' 0
}

worker() {
    local worker_dir="$1" slot_id="$2"; shift 2
    : "$worker_dir" "$slot_id" "$@"
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    "${ns}_scheduler_diagnose"
}
