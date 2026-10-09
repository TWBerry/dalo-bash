#!/usr/bin/env python3
"""Persistent Python payload store for DALO Payload Handle ABI v1."""

import os
import selectors
import sys



class CriticalPathTrace:
    """Write optional per-process monotonic events outside protocol FIFOs."""

    def __init__(self, role):
        """Initialize trace output. Parameters: role identifies this worker."""
        import time
        self.clock = time.monotonic_ns
        self.directory = os.environ.get("DALO_CP_TRACE_DIR", "")
        self.role = role
        self.stream = None
        if self.directory:
            os.makedirs(self.directory, exist_ok=True)
            self.stream = open(os.path.join(self.directory, f"{role}-{os.getpid()}.tsv"), "w", buffering=1, encoding="ascii")
            self.stream.write("timestamp_ns\trole\tpid\tkey\tevent\tvalue\n")

    def mark(self, key, event, value=""):
        """Record one timestamp. Parameters: key correlates a message, event names a boundary, value adds optional context."""
        if self.stream is not None:
            if isinstance(key, bytes):
                key = key.decode("utf-8", "backslashreplace")
            key = str(key).replace("\t", "\\t").replace("\n", "\\n")
            self.stream.write(f"{self.clock()}\t{self.role}\t{os.getpid()}\t{key}\t{event}\t{value}\n")

class DataPlaneProfiler:
    """Collect low-overhead per-process stage durations and emit periodic snapshots.

    Snapshots are optional and never use the measured protocol FIFOs. They are
    written to a unique per-process file, so independent workers do not contend.
    """

    def __init__(self, role):
        """Configure profiling from environment.

        Parameters:
            role: Human-readable worker role used in the snapshot filename.
        """
        import time
        self.clock = time.perf_counter_ns
        self.directory = os.environ.get("DALO_DP_PROFILE_DIR", "")
        self.role = role
        self.counters = {}
        self.events = 0
        self.interval = max(1, int(os.environ.get("DALO_DP_PROFILE_INTERVAL", "8")))
        if self.directory:
            os.makedirs(self.directory, exist_ok=True)
            import atexit
            import signal
            atexit.register(self.snapshot)
            # Preserve the default SIGTERM exit behavior while flushing counters.
            def terminate(signum, frame):
                """Flush on graceful termination.

                Parameters:
                    signum: Delivered signal number.
                    frame: Interrupted Python frame.
                """
                self.snapshot()
                raise SystemExit(128 + signum)
            signal.signal(signal.SIGTERM, terminate)

    def begin(self):
        """Return a monotonic timestamp, or zero when profiling is disabled.

        Parameters:
            none.
        """
        return self.clock() if self.directory else 0

    def add(self, name, start):
        """Accumulate one completed operation's duration.

        Parameters:
            name: Stable stage label.
            start: Timestamp returned by begin().
        """
        if not self.directory:
            return
        elapsed = self.clock() - start
        count, total = self.counters.get(name, (0, 0))
        self.counters[name] = (count + 1, total + elapsed)
        self.events += 1
        if self.events % self.interval == 0:
            self.snapshot()

    def snapshot(self):
        """Atomically publish current counters to a process-local TSV file.

        Parameters:
            none.
        """
        if not self.directory or not self.counters:
            return
        name = f"{self.role}-{os.getpid()}.tsv"
        destination = os.path.join(self.directory, name)
        temporary = destination + ".tmp"
        with open(temporary, "w", encoding="ascii") as output:
            output.write("role\tstage\tcount\ttotal_ns\n")
            for stage, (count, total) in sorted(self.counters.items()):
                output.write(f"{self.role}\t{stage}\t{count}\t{total}\n")
        os.replace(temporary, destination)


class NulFieldReader:
    """Read NUL-delimited binary fields efficiently from one persistent FIFO."""

    def __init__(self, stream, chunk_size=65536):
        """Initialize the reader.

        Parameters:
            stream: Binary file object providing fileno().
            chunk_size: Maximum number of bytes requested per os.read() refill.
        """
        self.fd = stream.fileno()
        self.chunk_size = chunk_size
        self.buffer = bytearray()

    def read_field(self):
        """Return the next NUL-delimited field as bytes.

        Parameters:
            none.
        """
        while True:
            pos = self.buffer.find(0)
            if pos >= 0:
                value = bytes(self.buffer[:pos])
                del self.buffer[: pos + 1]
                return value
            chunk = os.read(self.fd, self.chunk_size)
            if not chunk:
                raise EOFError("payload-handle request FIFO closed")
            self.buffer.extend(chunk)


def write_response(stream, status, value):
    """Write one two-field response to the Bash control plane.

    Parameters:
        stream: Binary response FIFO object.
        status: ASCII status token such as OK or ERR.
        value: Raw response bytes; may contain UTF-8 text but never NUL.
    """
    if b"\0" in status or b"\0" in value:
        raise ValueError("Payload Handle Bash boundary cannot carry NUL bytes")
    stream.write(status + b"\0" + value + b"\0")
    stream.flush()


class PayloadStore:
    """Own resident payload bytes and enforce handle generation/state semantics."""

    def __init__(self, store_id):
        """Initialize an empty store.

        Parameters:
            store_id: Stable identifier embedded into every descriptor from this store.
        """
        self.store_id = store_id
        self.next_handle_id = 0
        self.entries = {}

    def _descriptor(self, handle_id, generation, size):
        """Build one Payload Handle ABI v1 descriptor.

        Parameters:
            handle_id: Numeric identity of the resident payload entry.
            generation: Current ownership generation.
            size: Payload size in bytes.
        """
        return f"PH1|{self.store_id}|{handle_id}|{generation}|{size}".encode("ascii")

    def _parse(self, descriptor):
        """Validate descriptor syntax and return its numeric fields.

        Parameters:
            descriptor: Raw ASCII Payload Handle ABI v1 descriptor bytes.
        """
        try:
            version, store_id, handle_id, generation, size = descriptor.decode("ascii").split("|")
            if version != "PH1" or store_id != self.store_id:
                raise ValueError
            return int(handle_id), int(generation), int(size)
        except (UnicodeDecodeError, ValueError):
            raise ValueError("INVALID_HANDLE") from None

    def _owned_entry(self, descriptor):
        """Resolve a descriptor only when it names the current OWNED generation.

        Parameters:
            descriptor: Raw descriptor supplied by the Bash semantic plane.
        """
        handle_id, generation, size = self._parse(descriptor)
        entry = self.entries.get(handle_id)
        if entry is None:
            raise ValueError("UNKNOWN_HANDLE")
        if generation != entry["generation"]:
            raise ValueError("STALE_GENERATION")
        if size != entry["size"]:
            raise ValueError("SIZE_MISMATCH")
        if entry["state"] != "OWNED":
            raise ValueError(f"HANDLE_{entry['state']}")
        return handle_id, entry

    def store(self, payload):
        """Store payload bytes and return a new OWNED handle descriptor.

        Parameters:
            payload: Raw payload bytes entering the Python data plane.
        """
        self.next_handle_id += 1
        handle_id = self.next_handle_id
        entry = {"generation": 1, "size": len(payload), "state": "OWNED", "payload": payload}
        self.entries[handle_id] = entry
        return self._descriptor(handle_id, entry["generation"], entry["size"])

    def forward(self, descriptor):
        """Atomically transfer ownership and return the replacement handle.

        Parameters:
            descriptor: Current OWNED handle descriptor. The supplied generation becomes stale.
        """
        handle_id, entry = self._owned_entry(descriptor)
        entry["state"] = "IN_FLIGHT"
        entry["generation"] += 1
        entry["state"] = "OWNED"
        return self._descriptor(handle_id, entry["generation"], entry["size"])

    def send_to_line(self, descriptor, ingress_path, key):
        """Transfer resident payload directly into a Production Line ingress FIFO.

        Parameters:
            descriptor: Current OWNED handle descriptor.
            ingress_path: Filesystem path of the destination Production Line ingress FIFO.
            key: Logical record key bytes forwarded alongside the resident payload.
        """
        _, entry = self._owned_entry(descriptor)
        if b"\0" in key:
            raise ValueError("NUL_IN_KEY")
        try:
            path = ingress_path.decode("utf-8")
        except UnicodeDecodeError:
            raise ValueError("INVALID_INGRESS_PATH") from None
        entry["state"] = "IN_FLIGHT"
        self.trace.mark(key, "STORE_LINE_WRITE_BEGIN", len(entry["payload"]))
        try:
            t = self.profiler.begin() if hasattr(self, "profiler") else 0
            with open(path, "wb", buffering=0) as ingress:
                ingress.write(key + b"\0" + entry["payload"] + b"\0")
                ingress.flush()
            if hasattr(self, "profiler"):
                self.profiler.add("store_line_write", t)
        except Exception:
            entry["state"] = "OWNED"
            raise
        self.trace.mark(key, "STORE_LINE_WRITE_END")
        entry["state"] = "RELEASED"
        entry["payload"] = None
        return b"SENT"

    def materialize(self, descriptor):
        """Return resident payload bytes through the explicitly expensive Bash path.

        Parameters:
            descriptor: Current OWNED handle descriptor.
        """
        _, entry = self._owned_entry(descriptor)
        return entry["payload"]

    def release(self, descriptor):
        """Invalidate an OWNED handle while retaining a tombstone for stale detection.

        Parameters:
            descriptor: Current OWNED handle descriptor to release.
        """
        _, entry = self._owned_entry(descriptor)
        entry["state"] = "RELEASED"
        entry["payload"] = None
        return b"RELEASED"


def _serve_operation(store, reader, response):
    """Serve exactly one request from one Payload Store protocol plane.

    Parameters:
        store: PayloadStore instance owning all resident entries.
        reader: NulFieldReader bound to the selected request FIFO.
        response: Binary FIFO receiving the response for this same protocol plane.
    """
    profiler = store.profiler
    t = profiler.begin()
    op = reader.read_field()
    profiler.add("store_request_op_read", t)
    if op == b"STOP":
        write_response(response, b"OK", b"STOPPED")
        return False
    try:
        t = profiler.begin()
        argument = reader.read_field()
        profiler.add("store_request_arg_read", t)
        t = profiler.begin()
        if op == b"STORE":
            value = store.store(argument)
            store.trace.mark(value, "STORE_COMPLETE", len(argument))
        elif op == b"FORWARD":
            value = store.forward(argument)
        elif op == b"SEND_TO_LINE":
            ingress_path = reader.read_field()
            key = reader.read_field()
            value = store.send_to_line(argument, ingress_path, key)
        elif op == b"MATERIALIZE":
            value = store.materialize(argument)
        elif op == b"RELEASE":
            value = store.release(argument)
        else:
            raise ValueError("UNKNOWN_OPERATION")
        profiler.add("store_dispatch_" + op.decode("ascii", "replace"), t)
        t = profiler.begin()
        write_response(response, b"OK", value)
        profiler.add("store_response_write", t)
    except (EOFError, ValueError) as exc:
        write_response(response, b"ERR", str(exc).encode("ascii", "replace"))
    return True


def run(control_request_path, control_response_path, ingest_request_path, ingest_response_path, lifecycle_path, store_id):
    """Serve independent control and data-ingest planes for one payload store.

    Parameters:
        control_request_path: FIFO receiving small Bash control-plane requests.
        control_response_path: FIFO returning responses only to the Bash control plane.
        ingest_request_path: FIFO receiving large STORE records only from Python data-plane workers.
        ingest_response_path: FIFO returning STORE descriptors only to Python data-plane workers.
        lifecycle_path: FIFO used for lifecycle READY notification.
        store_id: Stable identifier for this store instance.
    """
    store = PayloadStore(store_id)
    store.profiler = DataPlaneProfiler("store_" + store_id.replace("/", "_"))
    store.trace = CriticalPathTrace("store_" + store_id.replace("/", "_"))
    with open(lifecycle_path, "w", encoding="ascii", buffering=1) as lifecycle:
        lifecycle.write("READY|PAYLOAD_STORE\n")
    with open(control_request_path, "rb", buffering=0) as control_request, \
            open(control_response_path, "wb", buffering=0) as control_response, \
            open(ingest_request_path, "rb", buffering=0) as ingest_request, \
            open(ingest_response_path, "wb", buffering=0) as ingest_response:
        control_reader = NulFieldReader(control_request)
        ingest_reader = NulFieldReader(ingest_request)
        selector = selectors.DefaultSelector()
        selector.register(control_request.fileno(), selectors.EVENT_READ, (control_reader, control_response, "control"))
        selector.register(ingest_request.fileno(), selectors.EVENT_READ, (ingest_reader, ingest_response, "ingest"))
        running = True
        while running:
            for key, _ in selector.select():
                reader, response, plane = key.data
                try:
                    running = _serve_operation(store, reader, response)
                except EOFError:
                    if plane == "control":
                        running = False
                    else:
                        selector.unregister(key.fd)
                if not running:
                    break

def main(argv):
    """Parse worker arguments and start the persistent payload store.

    Parameters:
        argv: Program arguments: request FIFO, response FIFO, control FIFO, store id.
    """
    if len(argv) != 7:
        raise SystemExit(
            "usage: payload_handle_worker.py CONTROL_REQUEST CONTROL_RESPONSE "
            "INGEST_REQUEST INGEST_RESPONSE LIFECYCLE STORE_ID"
        )
    run(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6])


if __name__ == "__main__":
    main(sys.argv)
