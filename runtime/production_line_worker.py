#!/usr/bin/env python3
"""Persistent Python data-plane worker for DALO production lines."""

import os
import sys
import queue
import threading
import struct
import select
import time

DELIM = "€♧¿"


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



class NulRecordReader:
    """Chunked reader for the Bash-compatible NUL-delimited boundary."""

    def __init__(self, stream, chunk_size=65536):
        """Initialize a delimiter reader.

        Parameters:
            stream: Binary file object providing fileno().
            chunk_size: Maximum bytes requested from the FIFO per refill.
        """
        self.fd = stream.fileno()
        self.chunk_size = chunk_size
        self.buffer = bytearray()

    def read_field(self):
        """Read and return one NUL-delimited field as raw bytes.

        Parameters:
            none.
        """
        while True:
            delimiter = self.buffer.find(0)
            if delimiter >= 0:
                value = bytes(self.buffer[:delimiter])
                del self.buffer[: delimiter + 1]
                return value
            chunk = os.read(self.fd, self.chunk_size)
            if not chunk:
                raise EOFError("production-line stream closed during NUL-delimited field")
            self.buffer.extend(chunk)

    def read_record(self):
        """Read one NUL-delimited key/payload record.

        Parameters:
            none.
        """
        return self.read_field(), self.read_field()


def failure_idle_timeout():
    """Return the maximum idle time for a data-plane operation.

    Parameters:
        none. DALO_PL_IDLE_TIMEOUT controls the deadline in seconds.
    """
    timeout = float(os.environ.get("DALO_PL_IDLE_TIMEOUT", "1.0"))
    if not 0 < timeout < 3600:
        raise ValueError("DALO_PL_IDLE_TIMEOUT must be between 0 and 3600 seconds")
    return timeout


def write_with_idle_deadline(stream, data, timeout):
    """Write bytes without allowing a non-reading FIFO peer to block forever.

    Parameters:
        stream: Open FIFO output file object with a file descriptor.
        data: Complete frame bytes to transmit.
        timeout: Maximum seconds without forward progress.

    A completed write is not an application-level delivery acknowledgement.
    """
    fd = stream.fileno()
    previous = os.get_blocking(fd)
    view = memoryview(data)
    offset = 0
    deadline = time.monotonic() + timeout
    os.set_blocking(fd, False)
    try:
        while offset < len(view):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("production-line transport write stalled")
            _, writable, _ = select.select([], [fd], [], remaining)
            if not writable:
                raise TimeoutError("production-line transport write stalled")
            try:
                written = os.write(fd, view[offset:])
            except BlockingIOError:
                continue
            if written <= 0:
                raise BrokenPipeError("production-line transport made no progress")
            offset += written
            deadline = time.monotonic() + timeout
    finally:
        os.set_blocking(fd, previous)


def read_nul_field_with_deadline(reader, timeout):
    """Read a NUL-delimited response field with an inactivity deadline.

    Parameters:
        reader: NulRecordReader retaining bytes already read from the FIFO.
        timeout: Maximum seconds without receiving additional bytes.
    """
    deadline = time.monotonic() + timeout
    while True:
        pos = reader.buffer.find(0)
        if pos >= 0:
            value = bytes(reader.buffer[:pos])
            del reader.buffer[:pos + 1]
            return value
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("payload store ACK stalled; delivery state uncertain")
        readable, _, _ = select.select([reader.fd], [], [], remaining)
        if not readable:
            raise TimeoutError("payload store ACK stalled; delivery state uncertain")
        chunk = os.read(reader.fd, reader.chunk_size)
        if not chunk:
            raise EOFError("payload store response closed; delivery state uncertain")
        reader.buffer.extend(chunk)
        deadline = time.monotonic() + timeout


def write_record(stream, key, payload):
    """Write one NUL-delimited key/payload record.

    Parameters:
        stream: Binary file object providing write() and flush().
        key: Raw UTF-8 key bytes.
        payload: Raw UTF-8 payload bytes.
    """
    if b"\0" in key or b"\0" in payload:
        raise ValueError("production-line Bash boundary cannot carry NUL bytes")
    stream.write(key)
    stream.write(b"\0")
    stream.write(payload)
    stream.write(b"\0")
    stream.flush()


def encode_field(value):
    """Encode one text field using the experimental Frame ABI v1 escaping.

    Parameters:
        value: Unicode field value to encode.
    """
    value = value.replace("%", "%25")
    value = value.replace("€", "%E282AC")
    value = value.replace("♧", "%E299A7")
    value = value.replace("¿", "%C2BF")
    value = value.replace("\t", "%09")
    value = value.replace("\n", "%0A")
    value = value.replace("\r", "%0D")
    return value


def decode_field(value):
    """Decode one field produced by encode_field().

    Parameters:
        value: Percent-escaped Unicode field value.
    """
    for encoded, raw in (("%0D", "\r"), ("%0A", "\n"), ("%09", "\t"), ("%C2BF", "¿"), ("%E299A7", "♧"), ("%E282AC", "€"), ("%25", "%")):
        value = value.replace(encoded, raw)
    return value


def encode_frame(key, payload):
    """Encode one logical output record into Frame ABI v1 wire bytes.

    Parameters:
        key: UTF-8 key bytes from the ingress record.
        payload: UTF-8 payload bytes from the ingress record.
    """
    key_text = key.decode("utf-8")
    payload_text = payload.decode("utf-8")
    frame = "O" + DELIM + "2" + DELIM + encode_field(key_text) + DELIM + encode_field(payload_text) + "\n"
    return frame.encode("utf-8")


def decode_frame(frame):
    """Decode one Frame ABI v1 wire frame into raw UTF-8 fields.

    Parameters:
        frame: Complete newline-free UTF-8 frame bytes.
    """
    fields = frame.decode("utf-8").split(DELIM)
    if len(fields) < 2 or not fields[1].isdigit():
        raise ValueError("invalid production-line frame header")
    argc = int(fields[1])
    if argc != 2 or len(fields) != argc + 2 or fields[0] != "O":
        raise ValueError("invalid production-line output frame")
    return decode_field(fields[2]).encode("utf-8"), decode_field(fields[3]).encode("utf-8")


BINARY_HEADER = struct.Struct("!II")
BINARY_MAX_FIELD = 64 * 1024 * 1024


def transport_mode():
    """Select the internal Production Line transport; no parameters.

    The setting affects only Python TX/RX FIFO framing, not Bash or OBJECT ABI.
    """
    mode = os.environ.get("DALO_PL_TRANSPORT", "text").lower()
    if mode not in ("text", "binary"):
        raise ValueError("DALO_PL_TRANSPORT must be text or binary")
    return mode


def encode_binary_frame(key, payload):
    """Encode length-prefixed binary data; key and payload are byte strings.

    Parameters:
        key: Logical record identifier as raw bytes.
        payload: Resident payload as raw bytes.
    """
    if len(key) > BINARY_MAX_FIELD or len(payload) > BINARY_MAX_FIELD:
        raise ValueError("binary production-line field exceeds size limit")
    return BINARY_HEADER.pack(len(key), len(payload)) + key + payload


def read_exact(stream, size):
    """Read exactly size bytes from a FIFO, rejecting premature EOF.

    Parameters:
        stream: Unbuffered binary FIFO input stream.
        size: Required number of bytes.
    """
    data = bytearray()
    while len(data) < size:
        block = stream.read(size - len(data))
        if not block:
            raise EOFError("truncated binary production-line frame")
        data.extend(block)
    return bytes(data)


def read_transport_frame(transport, mode):
    """Read one transport record or return None on clean EOF.

    Parameters:
        transport: Open unbuffered transport FIFO.
        mode: Selected text or binary framing mode.
    """
    if mode == "text":
        frame = transport.readline()
        if not frame:
            return None
        return decode_frame(frame.rstrip(b"\n"))
    first = transport.read(1)
    if not first:
        return None
    header = first + read_exact(transport, BINARY_HEADER.size - 1)
    key_size, payload_size = BINARY_HEADER.unpack(header)
    if key_size > BINARY_MAX_FIELD or payload_size > BINARY_MAX_FIELD:
        raise ValueError("binary production-line frame exceeds size limit")
    body = read_exact(transport, key_size + payload_size)
    return body[:key_size], body[key_size:]


def run_tx(ingress_path, transport_path, control_path):
    """Run the persistent TX half of one production line.

    Parameters:
        ingress_path: FIFO receiving NUL-delimited records from Bash.
        transport_path: FIFO carrying Python-encoded Frame ABI records to RX.
        control_path: FIFO used only for lifecycle READY notification.
    """
    mode = transport_mode()
    idle_timeout = failure_idle_timeout()
    profiler = DataPlaneProfiler("tx")
    trace = CriticalPathTrace("tx")
    with open(control_path, "w", encoding="ascii", buffering=1) as control:
        control.write("READY|TX\n")
    with open(ingress_path, "rb", buffering=0) as ingress, open(transport_path, "wb", buffering=0) as transport:
        reader = NulRecordReader(ingress)
        while True:
            t = profiler.begin()
            key, payload = reader.read_record()
            profiler.add("tx_ingress_read", t)
            trace.mark(key, "TX_INGRESS_READY", len(payload))
            if key == b"__DALO_PRODUCTION_LINE_STOP__" and payload == b"":
                break
            t = profiler.begin()
            encoded = encode_frame(key, payload) if mode == "text" else encode_binary_frame(key, payload)
            profiler.add("tx_encode", t)
            trace.mark(key, "TX_WRITE_BEGIN", len(encoded))
            t = profiler.begin()
            write_with_idle_deadline(transport, encoded, idle_timeout)
            profiler.add("tx_transport_write", t)
            trace.mark(key, "TX_WRITE_END", len(encoded))


def run_rx(transport_path, egress_path, control_path):
    """Run the persistent RX half of one production line.

    Parameters:
        transport_path: FIFO carrying Frame ABI records from TX.
        egress_path: FIFO receiving decoded NUL-delimited records for the Bash consumer.
        control_path: FIFO used only for lifecycle READY notification.
    """
    mode = transport_mode()
    with open(control_path, "w", encoding="ascii", buffering=1) as control:
        control.write("READY|RX\n")
    with open(transport_path, "rb", buffering=0) as transport, open(egress_path, "wb", buffering=0) as egress:
        while True:
            record = read_transport_frame(transport, mode)
            if record is None:
                break
            key, payload = record
            write_record(egress, key, payload)



def run_rx_handle_sink(transport_path, metadata_path, control_path, store_ingest_request_path, store_ingest_response_path):
    """Run RX while keeping payload bytes in the Python data plane.

    Parameters:
        transport_path: FIFO carrying Frame ABI records from TX.
        metadata_path: FIFO returning the logical key and PH1 descriptor to Bash.
        control_path: FIFO used only for lifecycle READY notification.
        store_ingest_request_path: Dedicated Payload Store ingest FIFO receiving STORE records.
        store_ingest_response_path: Dedicated Payload Store ingest response FIFO returning descriptors.
    """
    mode = transport_mode()
    idle_timeout = failure_idle_timeout()
    prefetch = int(os.environ.get("DALO_RX_PREFETCH", "0"))
    if prefetch < 0 or prefetch > 1024:
        raise ValueError("DALO_RX_PREFETCH must be between 0 and 1024")
    profiler = DataPlaneProfiler("rx_handle")
    trace = CriticalPathTrace("rx_handle")
    with open(control_path, "w", encoding="ascii", buffering=1) as control:
        control.write("READY|RX\n")
    with open(transport_path, "rb", buffering=0) as transport, \
            open(metadata_path, "wb", buffering=0) as metadata, \
            open(store_ingest_request_path, "wb", buffering=0) as store_request, \
            open(store_ingest_response_path, "rb", buffering=0) as store_response:
        response_reader = NulRecordReader(store_response)
        pending = queue.Queue(maxsize=prefetch) if prefetch else None
        eof = object()

        def read_frames():
            """Read and decode transport frames on a separate thread.

            Parameters:
                none. The closure uses the transport stream and bounded queue.
            """
            try:
                while True:
                    t = profiler.begin()
                    record = read_transport_frame(transport, mode)
                    profiler.add("rx_transport_read", t)
                    if record is None:
                        pending.put(eof)
                        return
                    t = profiler.begin()
                    key, payload = record
                    profiler.add("rx_decode", t)
                    trace.mark(key, "RX_FRAME_READY", len(payload))
                    pending.put((key, payload))
            except BaseException as exc:
                pending.put(exc)

        reader_thread = None
        if pending is not None:
            reader_thread = threading.Thread(target=read_frames, name="dalo-rx-prefetch", daemon=True)
            reader_thread.start()

        while True:
            if pending is None:
                t = profiler.begin()
                record = read_transport_frame(transport, mode)
                profiler.add("rx_transport_read", t)
                if record is None:
                    break
                t = profiler.begin()
                key, payload = record
                profiler.add("rx_decode", t)
                trace.mark(key, "RX_FRAME_READY", len(payload))
            else:
                item = pending.get()
                if item is eof:
                    break
                if isinstance(item, BaseException):
                    raise RuntimeError("RX prefetch reader failed") from item
                key, payload = item
            trace.mark(key, "RX_INGEST_BEGIN", len(payload))
            t = profiler.begin()
            store_request.write(b"STORE\0" + payload + b"\0")
            store_request.flush()
            profiler.add("rx_store_ingest_write", t)
            trace.mark(key, "RX_INGEST_WRITE_END")
            t = profiler.begin()
            status = read_nul_field_with_deadline(response_reader, idle_timeout)
            descriptor = read_nul_field_with_deadline(response_reader, idle_timeout)
            profiler.add("rx_store_ack_wait", t)
            trace.mark(key, "RX_STORE_ACK", descriptor.decode("ascii", "replace"))
            if status != b"OK":
                raise RuntimeError(f"payload store ingest failed: {descriptor.decode('ascii', 'replace')}")
            t = profiler.begin()
            metadata.write(key + b"\0" + descriptor + b"\0")
            metadata.flush()
            profiler.add("rx_metadata_write", t)
            trace.mark(key, "RX_METADATA_END")

        if reader_thread is not None:
            reader_thread.join(timeout=2)
            if reader_thread.is_alive():
                raise RuntimeError("RX prefetch reader did not terminate")


def main(argv):
    """Dispatch one persistent worker role.

    Parameters:
        argv: Command-line arguments: role plus three FIFO paths.
    """
    if len(argv) < 5:
        raise SystemExit("usage: production_line_worker.py ROLE PATH PATH CONTROL [STORE_REQUEST]")
    role = argv[1]
    if role == "tx" and len(argv) == 5:
        run_tx(argv[2], argv[3], argv[4])
    elif role == "rx" and len(argv) == 5:
        run_rx(argv[2], argv[3], argv[4])
    elif role == "rx_handle_sink" and len(argv) == 7:
        run_rx_handle_sink(argv[2], argv[3], argv[4], argv[5], argv[6])
    else:
        raise SystemExit(f"invalid production-line role/arguments: {role}")


if __name__ == "__main__":
    main(sys.argv)
