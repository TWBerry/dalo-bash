# DALO for Bash

**Distributed Asynchronous Library with Objects for Bash**

DALO is an object-based framework for modeling complex systems and constructing advanced asynchronous and distributed Bash pipelines with branching, workers, migration, and cross-machine execution.

## Model

```text
project.dalo
    |
    v
DALO compiler
    |
    v
async_script.bash
```

`.dalo` is the human-readable PROJECT source format. JSON descriptors define compile-time object, worker, feature, and INIT ABIs. The compiler resolves their dependency closures and lowers a PROJECT into a standalone Bash MACHINE.

The current development snapshot includes declarative OBJECT/WORKER/FEATURE definitions, Declarative INIT ABI v1, standalone runtime dependency/artifact linking, BRIDGE transport, migration support, and dynamic MACHINE discovery.

## Repository layout

- `runtime/` — DALO runtime and current compiler substrate
- `compiler/` — compiler components (next development stage)
- `definitions/objects/` — Object Definition ABI descriptors
- `definitions/workers/` — Worker Definition ABI descriptors
- `definitions/features/` — Feature Definition ABI descriptors
- `definitions/init/` — INIT descriptors and `artifacts/` containing INIT Bash implementations
- `examples/` — `.dalo` PROJECT examples
- `tests/` — validation/runtime tests
- `docs/` — architecture documentation

## Status

DALO is under active development. ABIs and source format may evolve while the compiler and object model are formalized.
