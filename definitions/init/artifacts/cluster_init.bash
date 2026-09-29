dalo_init_cluster() {
    local var port
    declare -A seen=()
    # PORT is local to a BRIDGE in this MACHINE image; PEER_PORT is remote.
    # Both are stable global identities, but discovery probes only remote ports.
    while IFS= read -r var; do
        [[ "$var" == *_FIELD_PORT ]] || continue
        port="${!var:-}"
        [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] || continue
        machine_endpoint_register_local "$port" || return
        seen["$port"]=1
    done < <(compgen -A variable 'm_')
    while IFS= read -r var; do
        [[ "$var" == *_FIELD_PEER_PORT ]] || continue
        port="${!var:-}"
        [[ -n "$port" && "$port" =~ ^[0-9]+$ ]] || continue
        machine_endpoint_register "$port" || return
        seen["$port"]=1
    done < <(compgen -A variable 'm_')
    ((${#seen[@]})) || return 66
    machine_discovery_scan24
}
