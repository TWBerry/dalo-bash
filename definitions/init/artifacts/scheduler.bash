# Initialize the unique scheduler namespace for this MACHINE.
# Parameters: none. The generated scheduler_OBJECT_TYPE variable identifies
# the fixed scheduler namespace; legacy m_* scheduler namespaces are accepted
# only to detect accidental duplicate scheduler objects.
dalo_init_scheduler() {
    local var ns found=""
    while IFS= read -r var; do
        case "$var" in
            scheduler_OBJECT_TYPE|m_*_OBJECT_TYPE) ;;
            *) continue ;;
        esac
        [[ "${!var:-}" == SCHEDULER ]] || continue
        ns="${var%_OBJECT_TYPE}"
        [[ -z "$found" ]] || {
            printf 'scheduler INIT: MACHINE contains more than one SCHEDULER OBJECT\n' >&2
            return 64
        }
        found="$ns"
    done < <(compgen -A variable)
    [[ -n "$found" ]] || {
        printf 'scheduler INIT: MACHINE has no SCHEDULER OBJECT\n' >&2
        return 66
    }
    DALO_MACHINE_SCHEDULER_NS="$found"
    export DALO_MACHINE_SCHEDULER_NS
}
