DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compiler-connect"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="compiler-ir compiler-definitions"

[ "${DALO_COMPILER_CONNECT_INCLUDE:-0}" -eq 0 ] || return 0
DALO_COMPILER_CONNECT_INCLUDE=1

dalo_connect_endpoint() {
    [ $# -eq 3 ] || return 2
    local endpoint="$1" object_var="$2" port_var="$3"
    local object port

    [[ "$endpoint" == *.* ]] || {
        printf 'daloc: endpoint must be object.port: %s\n' "$endpoint" >&2
        return 40
    }

    object="${endpoint%%.*}"
    port="${endpoint#*.}"

    [[ "$object" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 41
    [[ "$port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 41

    printf -v "$object_var" '%s' "$object"
    printf -v "$port_var" '%s' "$port"
}

dalo_connect_port_field() {
    [ $# -eq 4 ] || return 2
    local ir="$1" object="$2" port="$3" field="$4"
    local type file
    local -n types="${ir}_OBJECT_TYPE"

    [[ -v types["$object"] ]] || {
        printf 'daloc: CONNECT references unknown OBJECT %s\n' "$object" >&2
        return 42
    }

    type="${types[$object]}"
    file="${DALO_OBJECT_DEF_FILE[$type]:-}"
    [[ -n "$file" ]] || return 43

    jq -er --arg p "$port" --arg f "$field" '
        .ports[$p] as $port |
        if $port == null then error("unknown port")
        elif $port[$f] == null then error("unknown field")
        else $port[$f] end
    ' "$file" 2>/dev/null || {
        printf 'daloc: invalid port %s.%s\n' "$object" "$port" >&2
        return 44
    }
}

dalo_connect_infer_port() {
    [ $# -eq 3 ] || return 2
    local ir="$1" object="$2" direction="$3"
    local type file
    local -a ports=()
    local -n types="${ir}_OBJECT_TYPE"

    [[ -v types["$object"] ]] || return 42
    type="${types[$object]}"
    file="${DALO_OBJECT_DEF_FILE[$type]:-}"
    [[ -n "$file" ]] || return 43

    mapfile -t ports < <(
        jq -r --arg d "$direction" '
            .ports | to_entries[] |
            select(.value.direction == $d) |
            .key
        ' "$file" | LC_ALL=C sort
    )

    ((${#ports[@]} == 1)) || {
        printf 'daloc: VIA %s has %d %s ports; specify object.port\n' \
            "$object" "${#ports[@]}" "$direction" >&2
        return 45
    }

    printf '%s\n' "${ports[0]}"
}

dalo_connect_add_edge() {
    [ $# -eq 5 ] || return 2
    local ir="$1" ao="$2" ap="$3" bo="$4" bp="$5"
    local ad bd so sp do_ dp splane dplane stype dtype

    ad="$(dalo_connect_port_field "$ir" "$ao" "$ap" direction)" || return
    bd="$(dalo_connect_port_field "$ir" "$bo" "$bp" direction)" || return

    if [[ "$ad" == output && "$bd" == input ]]; then
        so="$ao"; sp="$ap"; do_="$bo"; dp="$bp"
    elif [[ "$bd" == output && "$ad" == input ]]; then
        so="$bo"; sp="$bp"; do_="$ao"; dp="$ap"
    else
        printf 'daloc: CONNECT requires output/input pair: %s.%s %s.%s\n' \
            "$ao" "$ap" "$bo" "$bp" >&2
        return 46
    fi

    splane="$(dalo_connect_port_field "$ir" "$so" "$sp" plane)" || return
    dplane="$(dalo_connect_port_field "$ir" "$do_" "$dp" plane)" || return
    [[ "$splane" == "$dplane" ]] || {
        printf 'daloc: edge plane mismatch: %s.%s -> %s.%s\n' "$so" "$sp" "$do_" "$dp" >&2
        return 47
    }

    stype="$(dalo_connect_port_field "$ir" "$so" "$sp" type)" || return
    dtype="$(dalo_connect_port_field "$ir" "$do_" "$dp" type)" || return
    [[ "$stype" == any || "$dtype" == any || "$stype" == "$dtype" ]] || {
        printf 'daloc: edge type mismatch: %s vs %s\n' "$stype" "$dtype" >&2
        return 48
    }

    dalo_ir_add_edge "$ir" "$so" "$sp" "$do_" "$dp"
}

dalo_connect_lower_one() {
    [ $# -eq 2 ] || return 2
    local ir="$1" text="$2"
    local -a token=()
    local current next via via_object via_port
    local po pp no np input_port output_port via_direction
    local i

    read -r -a token <<<"$text"
    ((${#token[@]} >= 2)) || {
        printf 'daloc: CONNECT requires at least two endpoints\n' >&2
        return 49
    }

    current="${token[0]}"
    i=1

    while ((i < ${#token[@]})); do
        if [[ "${token[i]}" != VIA ]]; then
            dalo_connect_endpoint "$current" po pp || return
            dalo_connect_endpoint "${token[i]}" no np || return
            dalo_connect_add_edge "$ir" "$po" "$pp" "$no" "$np" || return
            current="${token[i]}"
            ((++i))
            continue
        fi

        ((i + 2 < ${#token[@]})) || {
            printf 'daloc: VIA requires a via object and following endpoint\n' >&2
            return 50
        }

        via="${token[i+1]}"
        next="${token[i+2]}"

        dalo_connect_endpoint "$current" po pp || return
        dalo_connect_endpoint "$next" no np || return

        if [[ "$via" == *.* ]]; then
            via_object="${via%%.*}"
            via_port="${via#*.}"
            via_direction="$(dalo_connect_port_field "$ir" "$via_object" "$via_port" direction)" || return

            if [[ "$via_direction" == output ]]; then
                output_port="$via_port"
                input_port="$(dalo_connect_infer_port "$ir" "$via_object" input)" || return
            else
                input_port="$via_port"
                output_port="$(dalo_connect_infer_port "$ir" "$via_object" output)" || return
            fi
        else
            via_object="$via"
            input_port="$(dalo_connect_infer_port "$ir" "$via_object" input)" || return
            output_port="$(dalo_connect_infer_port "$ir" "$via_object" output)" || return
        fi

        dalo_connect_add_edge "$ir" "$po" "$pp" "$via_object" "$input_port" || return
        dalo_connect_add_edge "$ir" "$via_object" "$output_port" "$no" "$np" || return

        current="$next"
        ((i += 3))
    done
}

dalo_connect_lower_all() {
    [ $# -eq 1 ] || return 2
    local ir="$1" connect
    local -n connects="${ir}_CONNECT_TEXT"
    local -n edges="${ir}_EDGES"

    edges=()
    for connect in "${connects[@]}"; do
        dalo_connect_lower_one "$ir" "$connect" || return
    done
}
