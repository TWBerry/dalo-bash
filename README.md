# DALO — Distributed Asynchronous Library with Objects for Bash

DALO is a standalone Bash-oriented system for compiling a human-readable
`.dalo` PROJECT into an executable MACHINE. Objects, workers, features,
connections, and library dependencies are described declaratively; the
compiler resolves their definitions and emits the runtime wiring.

The architecture separates a logical PROJECT from the MACHINE that executes
it, and separates DATA transport from CONTROL. Local object state belongs
to its owning process. Distributed communication uses declarative BRIDGE
objects rather than a compiler-specific object type.

## Documentation

| Document | Scope |
| --- | --- |
| [Architecture](docs/architecture.md) | Core invariants, object model, execution, control, identity, and migration design |
| [Compiler](docs/compiler.md) | Parsing, IR, definitions, dependency closure, and standalone MACHINE generation |
| [PROJECT format](docs/dalo-format.md) | Human-readable `.dalo` declarations and semantics |
| [Libraries](docs/library.md) | Dependency-aware `include` loader and library metadata |
| [TCP bridge and cluster checkpoint](docs/bridge-cluster.md) | Framing, nonblocking receive, HELLO/ACK, and AB/BA validation |
| [Object library integration](docs/object-libraries-integration.md) | First compatibility-stage OBJECT `LIBRARIES` patch and limitations |
| [Helpers](docs/helpers.md) | Runtime helper APIs |
| [Iterators](docs/iterators.md) | Synchronous and asynchronous generators |
| [Fixed-point arithmetic](docs/fixed.md) | Q16.16 fixed-point ABI |

## Current distributed-runtime checkpoint

As of 2026-10-02, the two-MACHINE loopback harness passed both startup
orders, AB and BA, using the v11 nonblocking TCP bridge changes. Both
MACHINEs reported `ACTIVE`, and both processes exited with status 0.
The harness uses one-way `SCHED_CLUSTER_HELLO`: connector B initiates and
listener A responds with an ACK. These are **loopback harness results**;
they do not establish production scheduler integration, physical-LAN
interoperability, reconnection behavior, or authenticated remote control.

See [the bridge checkpoint](docs/bridge-cluster.md) for the verified scope,
protocol sequence, known limitations, and next validation steps.

## Development and tests

Compile PROJECTs using the compiler entry point documented in
[compiler.md](docs/compiler.md). Existing library integration tests include:

```bash
bash tests/test-object-libraries.bash
bash tests/test-fixed.bash
```

The two-MACHINE AB/BA harness is a separate local test environment; its
results should not be confused with an end-to-end physical-LAN test.
