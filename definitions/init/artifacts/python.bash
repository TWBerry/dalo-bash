dalo_init_python() {
    # runtime_requires=[python] loads and initializes the persistent Python runtime.
    declare -F inline_python >/dev/null 2>&1 || return 69
    declare -F init_python_thread >/dev/null 2>&1 || return 69
}
