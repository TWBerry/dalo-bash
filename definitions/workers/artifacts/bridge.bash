#!/usr/bin/env bash
# DALO BRIDGE worker artifact v2.
# Generic worker lifecycle entrypoints are declared in definitions/workers/bridge.json.
worker_start() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local init_var="${ns}_BRIDGE_WORKER_INITIALIZED"
    [[ "${!init_var:-0}" == 1 ]] && return 0
    declare -F init_python_thread >/dev/null 2>&1 || { printf 'BRIDGE[%s]: python runtime is not loaded\n' "$ns" >&2; return 69; }
    define_comm_api "$ns" || return
    define_tcp_capability_gate "$ns" || return
    local mode_var="${ns}_FIELD_MODE" host_var="${ns}_FIELD_HOST" port_var="${ns}_FIELD_PORT" peer_var="${ns}_FIELD_PEER"
    local mode="${!mode_var:-}" host="${!host_var:-}" port="${!port_var:-}" peer="${!peer_var:-}"
    [[ -n "$mode" && -n "$host" && -n "$port" && -n "$peer" ]] || { printf 'BRIDGE[%s]: incomplete descriptor fields\n' "$ns" >&2; return 64; }
    "${ns}_tcp_init" "$mode" "$host" "$port" "$ns" "$peer" || return
    printf -v "$init_var" '%s' 1
}
worker_poll() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local init_var="${ns}_BRIDGE_WORKER_INITIALIZED"
    [[ "${!init_var:-0}" == 1 ]] || return 69
    # timeout is intentionally short: lifecycle polling stays in the MACHINE owner.
    local hvar="${ns}_PYTHON_THREAD" handle ready
    handle="${!hvar:-}"
    [[ -n "$handle" ]] || return 1
    # Poll readiness in the same persistent interpreter/socket; do not fork a receiver.
    ready="$(inline_python -t "$handle" "__import__('select').select([_dalo_bridge_sock if _dalo_bridge_sock is not None else _dalo_bridge_server],[],[],0.02)[0] != []")" || return
    [[ "$ready" == True ]] || return 0
    "${ns}_bridge_receive_once" 0
}
worker_stop() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    declare -F "${ns}_tcp_close" >/dev/null 2>&1 && "${ns}_tcp_close" || true
    printf -v "${ns}_BRIDGE_WORKER_INITIALIZED" '%s' 0
}
worker() {
    local worker_dir="$1" slot_id="$2"; shift 2
    : "$worker_dir" "$slot_id"
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}" payload="$*"
    local init_var="${ns}_BRIDGE_WORKER_INITIALIZED"
    [[ "${!init_var:-0}" == 1 ]] || { printf 'BRIDGE[%s]: lifecycle not started\n' "$ns" >&2; return 69; }
    "${ns}_bridge_send_data" "$payload"
}
