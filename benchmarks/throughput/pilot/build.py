#!/usr/bin/env python3
"""Create isolated pilot cases from the validated compiled-recovery scenario."""
import argparse
from pathlib import Path


def main():
    """Generate a parameterized case; args select the source and output directories and payload size."""
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('size', type=int, choices=[1, 16, 256])
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)
    for name in ('probe.dalo', 'relay.bash', 'origin.bash', 'pipe.bash'):
        (args.destination / name).write_bytes((args.source / name).read_bytes())
    endpoint = (args.source / 'endpoint.bash').read_text()
    endpoint = endpoint.replace('\\|([a-z]{16})$', '\\|([a-z]+)$')
    (args.destination / 'endpoint.bash').write_text(endpoint)
    script = (args.source / 'test.sh').read_text()
    script = script.replace('DALO_ACK_BATCHES=8 DALO_ACK_PAYLOAD=abcdefghijklmnop',
                            f'DALO_ACK_BATCHES=8 DALO_ACK_PAYLOAD={"a" * args.size}')
    script = script.replace('"$DALO_ACK_BYTES" == 256', f'"$DALO_ACK_BYTES" == {16 * args.size}')
    script = script.replace('"$DALO_ACK_RECEIVED" == 16 && "$DALO_ACK_BYTES" == 256',
                            f'"$DALO_ACK_RECEIVED" == 16 && "$DALO_ACK_BYTES" == {16 * args.size}')
    script = script.replace('phase transfer_start', 'transfer_t0=${EPOCHREALTIME}\nphase transfer_start')
    script = script.replace('phase transfer_done', '''transfer_t1=${EPOCHREALTIME}
# Report end-to-end transfer including FIFO draining and sender completion.
# Parameters: transfer_t0 and transfer_t1 are Bash wall-clock timestamps.
awk -v a="$transfer_t0" -v b="$transfer_t1" -v bytes="$DALO_ACK_BYTES" \\
    'BEGIN {dt=b-a; printf "METRIC: seconds=%.6f bytes=%d messages=16 MiBps=%.6f msgps=%.3f\\n", dt, bytes, bytes/dt/1048576, 16/dt}'
phase transfer_done''')
    (args.destination / 'test.sh').write_text(script)


if __name__ == '__main__':
    main()
