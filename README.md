# DALO Supervisor SIGKILL regression v2

Adds Linux/Android PR_SET_PDEATHSIG(SIGKILL) to Python worker processes so an abruptly killed supervisor cannot leave active worker processes behind. Adds a bounded integration test using actual SIGKILL for both the last Bash client and its supervisor. The test uses its own mktemp directory and never removes the shared TMPDIR. This archive is incremental over Supervisor Recovery v1 and preserves its Bash API and affinity support.

Install from ~/dalo-bash:

    tar xzf /storage/emulated/0/Download/dalo-supervisor-sigkill-v2.tar.gz
    bash -n runtime/python.bashlib.sh tests/test-python-supervisor-sigkill.sh
    python3 -m py_compile runtime/python_supervisor.py
    timeout 60 bash tests/test-python-supervisor-recovery.sh
    timeout 60 bash tests/test-python-supervisor-sigkill.sh

Expected: five PASS lines total (three Recovery v1 plus two actual SIGKILL scenarios). The shell may print a `Killed` diagnostic for the intentionally killed supervisor; that is expected.

Linux/Android-specific worker parent-death enforcement is best effort on platforms where libc lacks prctl; the SIGKILL regression catches a failure to terminate workers. A pre-existing limitation remains: a client attaching to an unresponsive *live* supervisor can block on the legacy FIFO transport; a separate bounded transport handshake is needed to solve that fully.
