# DALO Sender Reap Integration v1 (experimental)

This patch adds a `F` failure frame on the existing ordered worker-to-parent FIFO after the persistent worker reaps a failed asynchronous sender with `wait`. The frame carries `sender.<PID>.<sequence>` and `EXIT_<wait-status>`; the parent dispatches it to `dalo_parent_sender_fail` and preserves pending ACK registrations for explicit reconciliation. Both the previous-sender wait and the final STOP wait emit the frame.

**Limits:** Failure detection happens when the worker reaches its next `wait` (next job or STOP); it is not yet proactive while the worker is idle. A failure frame is not a replay mechanism. A vector already acknowledged by the parent but whose sender dies before reading its ACK needs separate end-to-end delivery auditing. The test shipped here verifies integration source contracts and parent quarantine; the complete generated MACHINE must be tested on Termux with all project libraries installed.

Install in `~/dalo-bash-queue` after backing up `runtime/dalo.bashlib.sh`; do not install into the reference tree. Run `bash tests/test-sender-reap-integration.sh` and the existing quarantine and production DIRECT tests. To exercise the failure path in a generated MACHINE, the next fault-injection test must expose and SIGKILL the real sender PID before the persistent worker's next `wait`.
