dalo_init_scheduler() {
    local var ns found=""
    while IFS= read -r var; do
        [[ "$var" == m_*_OBJECT_TYPE ]] || continue
        [[ "${!var:-}" == SCHEDULER ]] || continue
        ns="${var%_OBJECT_TYPE}"
        [[ -z "$found" ]] || {
            printf 'scheduler INIT: MACHINE contains more than one SCHEDULER OBJECT\n' >&2
            return 64
        }
        found="$ns"
    done < <(compgen -A variable 'm_')
    [[ -n "$found" ]] || {
        printf 'scheduler INIT: MACHINE has no SCHEDULER OBJECT\n' >&2
        return 66
    }
    # Exactly one SCHEDULER exists physically.  Its stable logical CONTROL
    # endpoint is ns:scheduler; compiler-assigned m_* symbols stay local.
    DALO_MACHINE_SCHEDULER_NS="$found"
    export DALO_MACHINE_SCHEDULER_NS
}
