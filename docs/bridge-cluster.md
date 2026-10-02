# TCP BRIDGE and cluster handshake — v11 checkpoint

**Checkpoint date:** 2026-10-02  
**Evidence:** user-run two-MACHINE loopback harness, startup orders AB and BA  
**Scope:** verified test behavior and current design; not a claim of completed
production cluster support.

## 1. MACHINE identity and BRIDGE roles

DALO uses the stable BRIDGE TCP port as a MACHINE transport identity.
Runtime discovery resolves a peer's stable port to its current IPv4
address. `PORT` and `PEER_PORT` are transport metadata, not OBJECT DATA
ports. BRIDGE is an ordinary descriptor-driven OBJECT/WORKER.

The verified loopback setup uses:

| MACHINE | Stable port | Transport role | Handshake role |
| --- | ---: | --- | --- |
| A | `19101` | TCP listener | Passive responder |
| B | `19102` | TCP connector | Initiator |

AB and BA name **process startup order** only. They do not reverse TCP or
handshake roles. Both processes use the physical scheduler namespace
`scheduler`; BRIDGE uses `m_0001_bridge` in the tested generated MACHINEs.

## 2. Framing and nonblocking receive

The bridge transport carries UTF-8 payloads with an eight-byte,
network-byte-order unsigned payload-length prefix. TCP is a byte stream:
one `recv()` can return a partial header, a partial payload, or bytes from
multiple consecutive frames.

The v11 receive path retains partial frame bytes between worker polls.
An incomplete frame is a **not-ready condition**, not a broken connection;
the worker must yield to the scheduler and retry on subsequent polls.
The bridge worker treats the incomplete-frame return status (`75`) as
nonfatal. Completed frames are decoded and dispatched through the existing
bridge CONTROL forwarding path.

A successful ordinary HELLO/ACK exchange exercises the receive path but
is **not** proof that every fragmentation or disconnect boundary is safe.
The isolated receive tests performed during v11 development covered split
headers, split payloads, UTF-8, coalesced frames, and peer closure; a
separate integration stress test with deliberately fragmented network
writes remains a required regression.

## 3. CONTROL path and one-way handshake

The tested protocol has exactly one initiator: B sends
`SCHED_CLUSTER_HELLO` (`Q`) to A. A sends a matching response (`K`) to B.
The request ID must be preserved end to end.

```text
B scheduler                  B BRIDGE / TCP          A BRIDGE / TCP                 A scheduler
    |                               |                       |                              |
    |-- Q: SCHED_CLUSTER_HELLO ---->|------ TCP Q -------->|-- local scheduler FIFO ---->|
    |                               |                       |                              |
    |                               |<------ TCP K --------|<-- K: matching request ID ----|
    |<-- local scheduler FIFO K ----|                       |                              |
    |                               |                       |                              |
    +-- PENDING -> ACK -> ACTIVE    |                       +-- ACK sent -> ACTIVE --------+
```

On the passive side, the test harness defers final acceptance until the
ACK has been transmitted successfully. On the initiating side, the
matching `K` changes the outstanding request from `PENDING` to `ACK` and
permits `ACTIVE`. The v10/v11 harness polls BRIDGE FIFO and TCP receive
before scheduler FIFO processing, avoiding starvation of inbound CONTROL.

The `ACTIVE` transitions and deferred-ACK handling described here are
**harness behavior**. They must be audited and moved into the production
scheduler before the cluster protocol is declared production-ready.

## 4. Verified AB/BA results

The user ran the v11 loopback harness on 2026-10-02. The recorded summary:

| Startup order | A exit | B exit | A state | B state | Result |
| --- | ---: | ---: | --- | --- | --- |
| AB | 0 | 0 | ACTIVE | ACTIVE | PASS |
| BA | 0 | 0 | ACTIVE | ACTIVE | PASS |

The traces show B sending `Q`, A receiving and forwarding it to its local
scheduler, A sending `K`, and B matching `K` to its pending request.
The FIFO argument-preservation self-test also passed on both sides.

The loopback harness checks the peer's status through local shared status
files. This is a valid same-host test convenience, **not** a distributed
state-confirmation mechanism.

## 5. Remaining work and validation gates

1. Stress-test split eight-byte headers, split payloads, back-to-back
   frames, and disconnects during an incomplete frame at the integrated
   BRIDGE/worker level. Verify that no partial frame blocks scheduler FIFO
   progress and that session reset clears stale receive state.
2. Move the one-way HELLO/ACK lifecycle, pending request matching,
   deferred ACK transmission, and state transitions into the production
   scheduler. Retain a single initiator per tested peer relationship.
3. Audit per-MACHINE FIFO filesystem isolation. Sharing the logical
   namespace `scheduler` must not cause distinct local MACHINE processes
   to consume one another's physical FIFO messages.
4. Rebuild both generated MACHINEs from the updated production sources
   and repeat AB and BA in the loopback harness, including repeated runs.
5. Test on two physical LAN devices. Each MACHINE must establish its own
   `ACTIVE` state from received protocol messages; do not depend on shared
   filesystem status files. Separately test reversed TCP roles, delayed
   startup, peer disconnect/reconnect, and recovery transitions.
6. Review remote CONTROL authorization. FIFO encoding and TCP transport
   are not authentication or an authorization boundary.

## 6. Interpretation of the checkpoint

The v11 results show that the nonblocking TCP bridge change did not
regress the successful loopback HELLO/ACK path in either startup order.
They do not by themselves establish resilience to arbitrary TCP packet
fragmentation, successful reconnection, or production deployment.
