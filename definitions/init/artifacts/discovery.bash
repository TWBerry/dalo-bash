dalo_init_discovery() {
    # Python is guaranteed by the declarative INIT dependency closure.
    machine_discovery_detect_base24 >/dev/null || return
}
