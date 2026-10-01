#!/usr/bin/env bash
# DALO BRIDGE worker artifact v2.
# Generic worker lifecycle entrypoints are declared in definitions/workers/bridge.json.
_dalo_bridge_cluster_bind() {
    local ns="$1" mode_var="${1}_FIELD_MODE" port_var="${1}_FIELD_PORT" peer_var="${1}_FIELD_PEER_PORT"
    local mode="${!mode_var:-}" local_port="${!port_var:-}" peer="${!peer_var:-}"
    [[ "$local_port" =~ ^[0-9]+$ ]] || return 64
    # SCHEDULER is canonical and unique per MACHINE.  CONTROL is delivered to
    # that stable namespace; exact cluster operations remain capability-gated.
    "${ns}_bridge_bind_control_target" scheduler || return
    if [[ "$peer" =~ ^[0-9]+$ ]]; then
        "${ns}_tcp_cap_grant" "$peer" "$local_port" CLUSTER Q:SCHED_CLUSTER_HELLO || return
        "${ns}_tcp_cap_grant" "$peer" "$local_port" CLUSTER K:SCHED_CLUSTER_HELLO || return
        "${ns}_tcp_cap_grant" "$peer" "$local_port" CLUSTER E:SCHED_CLUSTER_HELLO || return
    fi
}

worker_start() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local init_var="${ns}_BRIDGE_WORKER_INITIALIZED" pending_var="${ns}_BRIDGE_DISCOVERY_PENDING"
    [[ "${!init_var:-0}" == 1 ]] && return 0
    declare -F init_python_thread >/dev/null 2>&1 || { printf 'BRIDGE[%s]: python runtime is not loaded\n' "$ns" >&2; return 69; }
    define_comm_api "$ns" || return
    define_fifo_api "$ns" || return
    define_tcp_capability_gate "$ns" || return
    _dalo_bridge_cluster_bind "$ns" || return
    local mode_var="${ns}_FIELD_MODE" port_var="${ns}_FIELD_PORT" peer_var="${ns}_FIELD_PEER_PORT"
    local mode="${!mode_var:-}" port="${!port_var:-}" peer="${!peer_var:-}" host endpoint local_port
    local_port="$port"
    [[ -n "$mode" && -n "$port" ]] || { printf 'BRIDGE[%s]: incomplete descriptor fields\n' "$ns" >&2; return 64; }
    case "$mode" in
        listen)
            host=0.0.0.0
            "${ns}_tcp_init" "$mode" "$host" "$port" "$local_port" "$peer" || return
            printf -v "$init_var" '%s' 1
            printf -v "$pending_var" '%s' 0
            ;;
        connect)
            [[ -n "$peer" ]] || { printf 'BRIDGE[%s]: connect mode requires PEER_PORT\n' "$ns" >&2; return 64; }
            if endpoint="$(machine_endpoint_resolve "$peer" 2>/dev/null)"; then
                IFS=$'\t' read -r host port <<<"$endpoint"
                if "${ns}_tcp_init" "$mode" "$host" "$port" "$local_port" "$peer"; then
                    printf -v "$init_var" '%s' 1
                    printf -v "$pending_var" '%s' 0
                    return 0
                fi
                machine_endpoint_invalidate "$peer" || return
            fi
            # On-demand convergence: unresolved connect workers remain alive but
            # allocate no transport until parent-owned worker_poll finds the peer.
            printf -v "$init_var" '%s' 0
            printf -v "$pending_var" '%s' 1
            ;;
        *) return 64;;
    esac
}
worker_poll() {
    local ns="${ASYNC_WORKER_NS:?missing ASYNC_WORKER_NS}"
    local init_var="${ns}_BRIDGE_WORKER_INITIALIZED" pending_var="${ns}_BRIDGE_DISCOVERY_PENDING"
    local mode_var="${ns}_FIELD_MODE" port_var="${ns}_FIELD_PORT" peer_var="${ns}_FIELD_PEER_PORT"
    local mode="${!mode_var:-}" local_port="${!port_var:-}" peer="${!peer_var:-}" endpoint host port

    if [[ "$mode" == connect && "${!init_var:-0}" != 1 ]]; then
        printf -v "$pending_var" '%s' 1
        # A scan is performed only while an expected peer is unresolved.  Once
        # all expected peers are mapped, discovery becomes completely idle.
        machine_discovery_scan24 >/dev/null 2>&1 || true
        endpoint="$(machine_endpoint_resolve "$peer" 2>/dev/null)" || return 0
        IFS=$'\t' read -r host port <<<"$endpoint"
        if "${ns}_tcp_init" connect "$host" "$port" "$local_port" "$peer"; then
            printf -v "$init_var" '%s' 1
            printf -v "$pending_var" '%s' 0
        else
            machine_endpoint_invalidate "$peer" || return
        fi
        return 0
    fi

    [[ "${!init_var:-0}" == 1 ]] || return 69
    # timeout is intentionally short: lifecycle polling stays in the MACHINE owner.
    local hvar="${ns}_PYTHON_THREAD" handle ready
    handle="${!hvar:-}"
    [[ -n "$handle" ]] || return 1
    ready="$(inline_python -t "$handle" "__import__('select').select([_dalo_bridge_sock if _dalo_bridge_sock is not None else _dalo_bridge_server],[],[],0.02)[0] != []")" || return
    [[ "$ready" == True ]] || return 0
    if ! "${ns}_bridge_receive_once" 0; then
        if [[ "$mode" == connect ]]; then
            # A failed established connection invalidates only the ephemeral IP
            # mapping.  Stable PORT identity remains and convergence restarts.
            "${ns}_tcp_close" || true
            machine_endpoint_invalidate "$peer" || return
            printf -v "$init_var" '%s' 0
            printf -v "$pending_var" '%s' 1
            return 0
        fi
        return 1
    fi
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
