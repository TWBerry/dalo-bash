#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="iterators"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="dalo helpers"
# DALO iterator/recursor library
#
# Oddělená knihovna generátorů synchronních/asynchronních iterátorů a DFS
# rekurzorů. Musí být načtena po dalo.bashlib.sh, protože async generátory
# používají DALO core API (__asyncobj_eval_body a namespaced job pool).
#
# Usage:
#   source ./dalo.bashlib.sh
#   source ./iterators.bashlib.sh

# DALO_INCLUDE=1 means this module is being consumed by DALO and generated
# bodies must go through __asyncobj_eval_body so they become part of the
# namespaced/canonical code image.  Standalone mode installs generated bodies
# directly with eval.

if [ "${ITERATORS_INCLUDE:-0}" -eq 0 ]; then
    ITERATORS_INCLUDE=1
else
    return 0
fi


: "${DALO_INCLUDE:=0}"

__dalo_iterator_install_body() {
    local ns="$1" component="$2" body="$3"
    if (( DALO_INCLUDE == 1 )); then
        if ! declare -F __asyncobj_eval_body >/dev/null 2>&1; then
            printf 'iterators.bashlib.sh: DALO_INCLUDE=1 requires dalo.bashlib.sh\n' >&2
            return 1
        fi
        __asyncobj_eval_body "$ns" "$component" "$body"
    else
        eval "$body"
    fi
}


# ============================================================================
# 1. SYNC ITERÁTORY
# ============================================================================

Make_iterator() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local array_name="$1" var_start="$2" var_end="$3" var_elem="$4" var_ret="$5"
    local body
    body=$(cat <<EOF
iterator_over_${array_name}() {
    local ${var_start}="\$1" ${var_end}="\$2"
    local func="\$3"; shift 3
    local idx
    for (( idx=${var_start}; idx<=${var_end}; idx++ )); do
        local ${var_elem}
        printf -v ${var_elem} '%s' "\${${array_name}[\$idx]}"
        local ${var_ret}=0
        "\$func" "\$idx" "\$${var_elem}" "\$@" || ${var_ret}=\$?
        [ "\$${var_ret}" -eq 0 ] || return "\$${var_ret}"
    done
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_file_iterator() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local gen_name="$1" var_line="$2" var_ret="$3"
    local body
    body=$(cat <<EOF
${gen_name}() {
    local _file="\$1" _func="\$2"; shift 2
    [ -r "\$_file" ] || return 1
    local ${var_line} ${var_ret}=0 _ln=0
    while IFS= read -r ${var_line} || [ -n "\$${var_line}" ]; do
        _ln=\$(( _ln + 1 ))
        [ -n "\$${var_line}" ] || continue
        ${var_ret}=0
        "\$_func" "\$_ln" "\$${var_line}" "\$@" || ${var_ret}=\$?
        [ "\$${var_ret}" -eq 0 ] || return "\$${var_ret}"
    done < "\$_file"
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_range_iterator() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local gen_name="$1" var_i="$2" var_ret="$3"
    local body
    body=$(cat <<EOF
${gen_name}() {
    local _start="\$1" _end="\$2" _step="\$3" _func="\$4"; shift 4
    local ${var_i} ${var_ret}=0
    for (( ${var_i}=_start; ${var_i}<=_end; ${var_i}+=_step )); do
        ${var_ret}=0
        "\$_func" "\$${var_i}" "\$@" || ${var_ret}=\$?
        [ "\$${var_ret}" -eq 0 ] || return "\$${var_ret}"
    done
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_xy_iterator() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local gen_name="$1" var_x="$2" var_y="$3" var_ret="$4"
    local body
    body=$(cat <<EOF
${gen_name}() {
    local _xs="\$1" _xe="\$2" _yoff="\$3" _ye="\$4" _ystep="\$5" _func="\$6"; shift 6
    local ${var_x} ${var_y} ${var_ret}=0
    for (( ${var_x}=_xs; ${var_x}<=_xe; ${var_x}++ )); do
        for (( ${var_y}=${var_x}+_yoff; ${var_y}<=_ye; ${var_y}+=_ystep )); do
            ${var_ret}=0
            "\$_func" "\$${var_x}" "\$${var_y}" "\$@" || ${var_ret}=\$?
            [ "\$${var_ret}" -eq 0 ] || return "\$${var_ret}"
        done
    done
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_glob_iterator() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local gen_name="$1" var_path="$2" var_ret="$3"
    local body
    body=$(cat <<EOF
${gen_name}() {
    local _pattern="\$1" _func="\$2"; shift 2
    local _on="\$(shopt -p nullglob)" _od="\$(shopt -p dotglob)"
    shopt -s nullglob dotglob
    local ${var_path} ${var_ret}=0
    for ${var_path} in \$_pattern; do
        ${var_ret}=0
        "\$_func" "\$${var_path}" "\$@" || ${var_ret}=\$?
        if [ "\$${var_ret}" -ne 0 ]; then
            eval "\$_on"; eval "\$_od"; return "\$${var_ret}"
        fi
    done
    eval "\$_on"; eval "\$_od"
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_dir_glob_iterator() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local gen_name="$1" var_path="$2" var_ret="$3"
    local body
    body=$(cat <<EOF
${gen_name}() {
    local _pattern="\$1" _func="\$2"; shift 2
    local _on="\$(shopt -p nullglob)" _od="\$(shopt -p dotglob)"
    shopt -s nullglob dotglob
    local ${var_path} ${var_ret}=0
    for ${var_path} in \$_pattern; do
        [ -d "\$${var_path}" ] || continue
        ${var_path}="\${${var_path}%/}"
        ${var_ret}=0
        "\$_func" "\$${var_path}" "\$@" || ${var_ret}=\$?
        if [ "\$${var_ret}" -ne 0 ]; then
            eval "\$_on"; eval "\$_od"; return "\$${var_ret}"
        fi
    done
    eval "\$_on"; eval "\$_od"
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 2. SYNC REKURZOR (DFS)
# ============================================================================

Make_recursor() {
    local ns=""
    if (( DALO_INCLUDE == 1 )); then
        ns="$1"; shift
    fi
    local gen_name="$1" var_path="$2"
    local body
    body=$(cat <<EOF
${gen_name}() {
    local ${var_path}="\$1" _enter="\$2" _leave="\$3"; shift 3
    if [ -n "\$_enter" ]; then "\$_enter" "\$${var_path}" "\$@" || return \$?; fi
    local _on="\$(shopt -p nullglob)"; shopt -s nullglob
    local _sub
    for _sub in "\$${var_path}"/*/; do
        [ -d "\$_sub" ] || continue
        ${gen_name} "\${_sub%/}" "\$_enter" "\$_leave" "\$@" || {
            local _rc=\$?; eval "\$_on"; return \$_rc
        }
    done
    eval "\$_on"
    if [ -n "\$_leave" ]; then "\$_leave" "\$${var_path}" "\$@" || return \$?; fi
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 3. ASYNC ITERÁTORY
# ============================================================================

Make_async_iterator() {
    local ns="$1" array_name="$2" var_start="$3" var_end="$4" var_elem="$5"
    local body
    body=$(cat <<EOF
${ns}_async_iterator_over_${array_name}() {
    local ${var_start}="\$1" ${var_end}="\$2"
    local func="\$3" cleanup_func="\${4:-}"
    shift 4 2>/dev/null || shift \$#
    local idx
    for (( idx=${var_start}; idx<=${var_end}; idx++ )); do
        local ${var_elem}
        printf -v ${var_elem} '%s' "\${${array_name}[\$idx]}"
        ${ns}_job_pool_submit "\$func" "\$cleanup_func" "\$${var_elem}" "\$@"
    done
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_async_file_iterator() {
    local ns="$1" var_line="$2"
    local body
    body=$(cat <<EOF
${ns}_async_iterator_over_file() {
    local _file="\$1" _func="\$2" _cleanup="\${3:-}"
    shift 3 2>/dev/null || shift \$#
    [ -r "\$_file" ] || return 1
    local ${var_line} _ln=0
    while IFS= read -r ${var_line} || [ -n "\$${var_line}" ]; do
        _ln=\$(( _ln + 1 ))
        [ -n "\$${var_line}" ] || continue
        ${ns}_job_pool_submit "\$_func" "\$_cleanup" "\$${var_line}" "\$@"
    done < "\$_file"
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_async_range_iterator() {
    local ns="$1" var_i="$2"
    local body
    body=$(cat <<EOF
${ns}_async_iterator_over_range() {
    local _start="\$1" _end="\$2" _step="\$3" _func="\$4" _cleanup="\${5:-}"
    shift 5 2>/dev/null || shift \$#
    local ${var_i}
    for (( ${var_i}=_start; ${var_i}<=_end; ${var_i}+=_step )); do
        ${ns}_job_pool_submit "\$_func" "\$_cleanup" "\$${var_i}" "\$@"
    done
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_async_xy_iterator() {
    local ns="$1" var_x="$2" var_y="$3"
    local body
    body=$(cat <<EOF
${ns}_async_iterator_over_xy() {
    local _xs="\$1" _xe="\$2" _yoff="\$3" _ye="\$4" _ystep="\$5"
    local _func="\$6" _cleanup="\${7:-}"
    shift 7 2>/dev/null || shift \$#
    local ${var_x} ${var_y}
    for (( ${var_x}=_xs; ${var_x}<=_xe; ${var_x}++ )); do
        for (( ${var_y}=${var_x}+_yoff; ${var_y}<=_ye; ${var_y}+=_ystep )); do
            ${ns}_job_pool_submit "\$_func" "\$_cleanup" "\$${var_x}" "\$${var_y}" "\$@"
        done
    done
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_async_glob_iterator() {
    local ns="$1" var_path="$2"
    local body
    body=$(cat <<EOF
${ns}_async_iterator_over_glob() {
    local _pattern="\$1" _func="\$2" _cleanup="\${3:-}"
    shift 3 2>/dev/null || shift \$#
    local _on="\$(shopt -p nullglob)" _od="\$(shopt -p dotglob)"
    shopt -s nullglob dotglob
    local ${var_path}
    for ${var_path} in \$_pattern; do
        ${ns}_job_pool_submit "\$_func" "\$_cleanup" "\$${var_path}" "\$@"
    done
    eval "\$_on"; eval "\$_od"
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

Make_async_dir_glob_iterator() {
    local ns="$1" var_path="$2"
    local body
    body=$(cat <<EOF
${ns}_async_iterator_over_dir_glob() {
    local _pattern="\$1" _func="\$2" _cleanup="\${3:-}"
    shift 3 2>/dev/null || shift \$#
    local _on="\$(shopt -p nullglob)" _od="\$(shopt -p dotglob)"
    shopt -s nullglob dotglob
    local ${var_path}
    for ${var_path} in \$_pattern; do
        [ -d "\$${var_path}" ] || continue
        ${var_path}="\${${var_path}%/}"
        ${ns}_job_pool_submit "\$_func" "\$_cleanup" "\$${var_path}" "\$@"
    done
    eval "\$_on"; eval "\$_od"
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 4. ASYNC REKURZOR
# ============================================================================

Make_async_recursor() {
    local ns="$1" gen_name="$2" var_path="$3"
    local body
    body=$(cat <<EOF
${ns}_${gen_name}() {
    local _root="\$1" _enter="\$2" _leave="\$3" _cleanup="\${4:-}"
    shift 4 2>/dev/null || shift \$#
    ${ns}_${gen_name}_impl "\$_root" "\$_enter" "\$_leave" "\$_cleanup" "\$@"
}

${ns}_${gen_name}_impl() {
    local ${var_path}="\$1" _enter="\$2" _leave="\$3" _cleanup="\$4"; shift 4
    if [ -n "\$_enter" ]; then "\$_enter" "\$${var_path}" "\$@" || return \$?; fi
    local _on="\$(shopt -p nullglob)"; shopt -s nullglob
    local _sub
    for _sub in "\$${var_path}"/*/; do
        [ -d "\$_sub" ] || continue
        ${ns}_${gen_name}_impl "\${_sub%/}" "\$_enter" "\$_leave" "\$_cleanup" "\$@" || {
            local _rc=\$?; eval "\$_on"; return \$_rc
        }
    done
    eval "\$_on"
    if [ -n "\$_leave" ]; then
        ${ns}_job_pool_submit "\$_leave" "\$_cleanup" "\$${var_path}" "\$@"
    fi
}
EOF
)
    __dalo_iterator_install_body "$ns" "${FUNCNAME[0]}" "$body"
}

