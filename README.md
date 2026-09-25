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

`.dalo` is the human-readable PROJECT source format. JSON descriptors define compile-time object, worker, and feature ABIs. The compiler lowers a PROJECT into a standalone Bash MACHINE.

The current development snapshot contains Object Definition ABI v1 and the first formal object descriptors: ORIGIN, PIPE, ENDPOINT, T, Y, and BIFURCATOR.

## Repository layout

- `runtime/` — DALO runtime and current compiler substrate
- `compiler/` — compiler components (next development stage)
- `definitions/objects/` — Object Definition ABI descriptors
- `definitions/workers/` — Worker Definition ABI descriptors
- `definitions/features/` — Feature Definition ABI descriptors
- `examples/` — `.dalo` PROJECT examples
- `tests/` — validation/runtime tests
- `docs/` — architecture documentation

## Status

DALO is under active development. ABIs and source format may evolve while the compiler and object model are formalized.
