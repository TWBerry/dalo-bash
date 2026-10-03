#!/usr/bin/env bash
# Exercise child-process FIFO delivery to MACHINE PARENT_WORKER and PARENT_HOOK.
set -euo pipefail

# Run the integration probe against a compiled MACHINE image.
# Parameters: $1 is the generated MACHINE Bash file.
main() {
    local image="${1:-benchmarks/parent-dispatch/parent_dispatch_probe.dalo.bash}"
    local ns='' name_var candidate child_pid='' child_rc=0 i output='' rc=0
    [[ -r "$image" ]] || { printf 'Missing MACHINE image: %s\n' "$image" >&2; return 2; }
    source "$image"
    # Discover the generated origin namespace without assuming object numbering.
    for name_var in $(compgen -A variable); do
        [[ "$name_var" == *_OBJECT_NAME ]] || continue
        [[ "${!name_var:-}" == origin ]] || continue
        ns="${name_var%_OBJECT_NAME}"
        break
    done
    [[ -n "$ns" ]] || { printf 'FAIL: origin namespace not found\n' >&2; return 3; }
    local fdvar="${ns}_FIFO_FD" fd=""
    fd="${!fdvar:-}"
    [[ -n "$fd" ]] || { printf 'FAIL: origin FIFO FD not initialized\n' >&2; return 4; }
    local parent_pid="$BASHPID"
    local result_file
    result_file="$(mktemp)" || return
    # Child inherits the existing FIFO write descriptor, exactly as a forked
    # OBJECT worker does. Parent alone drains and dispatches received frames.
    (
        [[ "$BASHPID" != "$parent_pid" ]] || exit 11
        "${ns}_fifo_send" P origin origin hello || exit 12
        "${ns}_fifo_send" P origin endpoint hello || exit 13
    ) &
    child_pid=$!
    # Capture the parent's actual dispatch output without draining in a
    # command substitution (which would execute dispatch in a subshell).
    for ((i=0; i<200; i++)); do
        "${ns}_drain_fifo" >>"$result_file" || { rc=$?; break; }
        if [[ "$(<"$result_file")" == *'PARENT source=origin target=origin bytes=5'* &&
              "$(<"$result_file")" == *'HOOK source=origin target=endpoint bytes=5'* ]]; then
            break
        fi
        sleep 0.01
    done
    wait "$child_pid" || child_rc=$?
    output="$(<"$result_file")"
    rm -f -- "$result_file"
    printf '%s\n' "$output"
    ((rc == 0 && child_rc == 0)) || { printf 'FAIL: drain=%s child=%s\n' "$rc" "$child_rc" >&2; return 1; }
    [[ "$output" == *'PARENT source=origin target=origin bytes=5'* &&
       "$output" == *'HOOK source=origin target=endpoint bytes=5'* ]] || {
        printf 'FAIL: expected parent and hook output not observed\n' >&2
        return 1
    }
    printf 'PASS: child process -> FIFO -> parent dispatcher -> PARENT_WORKER/PARENT_HOOK\n'
}
main "$@"
