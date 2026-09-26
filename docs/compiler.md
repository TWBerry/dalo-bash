# DALO Compiler

## 1. Purpose

The DALO compiler converts a human-readable `.dalo` PROJECT into a
standalone executable Bash MACHINE.

``` text
PROJECT.dalo
    │
    ▼
parser
    │
    ▼
compiler IR
    │
    ├── Object Definition ABI
    ├── Worker Definition ABI
    └── Feature Definition ABI
    │
    ▼
semantic validation
    │
    ▼
CONNECT/VIA lowering
    │
    ▼
feature closure
    │
    ▼
selective construction/linking
    │
    ▼
<PROJECT-NAME>.dalo.bash
```

The generated MACHINE is an executable artifact. Compiler descriptors
and `jq` are compile-time concerns and must not become accidental
runtime dependencies.

## 2. Compiler/runtime boundary

The compiler lives under `compiler/`; reusable execution mechanisms live
under `runtime/`.

A central loading invariant is:

> Compiler components do not directly `source` one another.

The compiler entry point directly sources only the DALO library loader
and then uses `include`.

Conceptually:

``` bash
ROOT=...
DALO_LIBRARY_PATH="$ROOT/compiler:$ROOT/runtime"
export DALO_LIBRARY_PATH

source "$ROOT/runtime/library.sh"

include dalo
include compiler-parser
include compiler-definitions
include compiler-connect
include compiler-features
include compiler-linker
```

This keeps compiler modules subject to the same metadata, dependency,
syntax, and cycle checks as other DALO libraries.

## 3. Entry point: `compiler/daloc.bash`

Current usage:

``` bash
./compiler/daloc.bash PROJECT.dalo
```

The compiler:

1.  determines the repository/compiler root;
2.  establishes compiler/runtime library search paths;
3.  loads required compiler/runtime libraries;
4.  loads JSON definition trees;
5.  parses PROJECT source into IR;
6.  validates descriptor-driven semantics;
7.  lowers CONNECT/VIA to canonical edges;
8.  resolves feature requirements;
9.  links a standalone MACHINE;
10. prints the output path.

PROJECT metadata determines the output name:

``` text
PROJECT
    NAME demo
    VERSION 1.0
```

produces:

``` text
demo.dalo.bash
```

in the PROJECT source directory.

## 4. Compiler modules

### `compiler-parser.bashlib.sh`

Responsibilities:

-   lexical/indentation validation;
-   top-level PROJECT/OBJECT/CONNECT recognition;
-   PROJECT metadata parsing;
-   generic uppercase object-field parsing;
-   nested WORKER block parsing;
-   source-location-aware diagnostics where available;
-   population of compiler IR.

The parser should not become the semantic authority for every object
type. It recognizes generic object fields; descriptors decide whether
those fields are legal.

### `compiler-ir.bashlib.sh`

Owns the canonical compiler-side representation.

The IR contains structures conceptually equivalent to:

``` text
PROJECT name/version
OBJECT list
OBJECT_TYPE[obj]
OBJECT_FIELD[obj|field]
WORKER_CODE[obj]
WORKER_TYPE[obj]
WORKER_EXECUTION[obj]
CONNECT source text
EDGE canonical records
FEATURE closure
```

Canonical edges are stored as structured/tab-separated records rather
than preserving raw source syntax.

The IR is a compiler representation, not runtime state.

### `compiler-definitions.bashlib.sh`

Loads and validates JSON descriptors from:

``` text
definitions/features/*.json
definitions/objects/*.json
definitions/workers/*.json
```

Current ABI constants include:

``` text
DALO_OBJECT_DEFINITION_ABI=1
DALO_FEATURE_DEFINITION_ABI=1
DALO_WORKER_DEFINITION_ABI=1
```

The loader must tolerate an empty descriptor class correctly: unmatched
globs are skipped, not treated as an implicit early return from the
whole definition-loading function.

### `compiler-connect.bashlib.sh`

Resolves human-readable CONNECT/VIA syntax into canonical graph edges.

Responsibilities include:

-   object lookup;
-   port lookup;
-   fixed/dynamic port validation;
-   source-output/destination-input validation;
-   plane compatibility;
-   type compatibility;
-   VIA expansion;
-   canonical EDGE creation.

The runtime linker should consume canonical edges, not re-parse PROJECT
connection text.

### `compiler-features.bashlib.sh`

Computes descriptor-driven feature closure.

Feature requirements originate from Object Definition JSON and
dependencies originate from Feature Definition JSON.

Example:

``` text
structural
   ↓ requires
 data
   ↓ requires
 core
```

If an object descriptor additionally declares `worker`, that requirement
is part of the closure because the descriptor says so, not because the
compiler recognizes a particular object type by name.

The JSON-driven closure has been validated by changing descriptor
feature lists and observing corresponding closure changes without
compiler hard-coding.

### `compiler-linker.bashlib.sh`

Adapts compiler IR into the established runtime MACHINE-linking backend.

This is intentionally not a second independent executable-runtime
implementation. DALO's runtime metafunctions remain the source of
executable object mechanisms; the compiler selects and specializes them.

The linker is responsible for:

-   namespace/object materialization;
-   worker source linkage;
-   execution-mode selection;
-   canonical edge routing;
-   embedding required runtime/helper code;
-   producing the final standalone Bash MACHINE.

## 5. Definition ABIs

### 5.1 Object Definition ABI v1

Object descriptors define what an object type structurally is.

A descriptor can define:

-   ABI version;
-   type and human-readable name;
-   fixed ports;
-   dynamic `port_patterns`;
-   instance fields and constraints;
-   methods;
-   required features;
-   worker requirement;
-   allowed execution modes.

COLUMN demonstrates dynamic bounded ports and instance fields.

The compiler, not the runtime MACHINE, consumes these descriptors.

### 5.2 Feature Definition ABI v1

Feature descriptors have an ABI, name, and dependency list.

Examples:

``` json
{"abi":1,"name":"core","requires":[]}
{"abi":1,"name":"data","requires":["core"]}
{"abi":1,"name":"worker","requires":["data"]}
{"abi":1,"name":"structural","requires":["data"]}
```

The compiler resolves transitive closure and uses it to drive selective
construction/linking.

### 5.3 Worker Definition ABI v1

Worker descriptors provide compile-time information about worker
artifacts/compatibility. PROJECT instances additionally provide the
nested WORKER block that selects concrete code, linkage mode, and
execution mode.

Worker source validation occurs at compile time. A standalone MACHINE
must not need the source tree after successful inline linkage.

## 6. Worker linkage

Current PROJECT worker block:

``` text
WORKER
    CODE workers/example.bash
    TYPE inline
    EXECUTION ASYNC
```

`CODE` is resolved relative to the PROJECT.

`TYPE inline` means the implementation is physically linked into the
generated MACHINE.

`TYPE include` is a distinct linkage model. It may be parsed, but the
standalone linker must reject it until exact standalone/external-library
semantics are implemented. Silent fallback to inline or unresolved
runtime sourcing would violate the compiler contract.

Before linking Bash worker source, the compiler validates it with
`bash -n`.

## 7. Execution modes

Execution selection is stored independently in IR:

``` text
WORKER_EXECUTION[obj]
```

Supported current modes:

``` text
INLINE
ASYNC
PERSISTENT
```

Default:

``` text
INLINE
```

The compiler validates the selected mode against the object descriptor's
allowed execution list.

### INLINE lowering

Worker executes in the owning shell. DATA vectors and canonical EDGE
routing remain local/direct.

### ASYNC lowering

Jobs execute in child processes. The parent owns canonical state;
child→parent completion and state mutation cross the per-object FIFO
boundary.

### PERSISTENT lowering

Long-lived children receive parent→child DATA through a direct process
channel. Child→parent results/control use the per-object FIFO.

The compiler must not implement PERSISTENT by turning the object FIFO
into a parent→child DATA queue.

## 8. Port-aware DATA ABI

The compiler/runtime contract preserves input/output identity:

``` text
INPUT_DATA_VECTOR["slot|input-port"]
OUTPUT_DATA_VECTOR["slot|output-port"]
```

Public invocation:

``` bash
object_summon_worker input_port DATA...
```

Generic edge forwarding calls the destination with the exact destination
port.

This replaces legacy scalar aliases that discarded port identity.

## 9. Generic EDGE routing

The linker resolves canonical edges into concrete runtime routes.

The current direction is generic routing rather than T/Y-specific
forwarding hooks. Structural object behavior is expressed through
descriptors/features/workers and the canonical edge graph.

This allows COLUMN and future object types to use the same routing
mechanism.

Runtime routing should remain mutable enough for future
ORCHESTRATOR-controlled rewiring; generated mechanisms may be
specialized, while concrete topology is canonical state.

## 10. Selective constructor/linker model

DALO keeps namespace-specialized metafunctions.

The optimization goal is not to flatten all objects into generic
wrappers. Instead:

``` text
Feature Definition ABI
        │
        ▼
required feature closure
        │
        ▼
required Make_* construction components
        │
        ▼
specialized object code
```

Metafunctions provide two outputs from one source of truth:

``` text
feature template
   ├── substitute/eval → live specialized runtime function
   └── record code     → canonical reconstruction/migration image
```

This is why `Make_*` families are architectural, not temporary
code-generation scaffolding.

## 11. Standalone MACHINE contract

A successfully linked inline MACHINE is intended to run independently
of:

-   `compiler/`;
-   JSON definitions;
-   worker source files that were embedded;
-   `jq`;
-   the repository checkout.

The linker embeds the runtime/helper code required by the generated
artifact.

A strong validation pattern is:

1.  compile PROJECT;
2.  move only the generated MACHINE to an isolated directory;
3.  remove/unavailable compiler definitions and worker sources;
4.  execute MACHINE;
5.  verify graph result.

This test has been used for the current end-to-end compiler checkpoint.

## 12. PROJECT quiescence

Object-local waiting is insufficient for a graph because upstream
completion can create downstream work after the downstream object was
previously idle.

Therefore the generated MACHINE exposes PROJECT-level quiescence
semantics.

Conceptually:

``` text
repeat
    drain/reconcile object child→parent channels
    reap/process asynchronous completions
    allow completion hooks to propagate DATA
    inspect pending/in-flight state
until no graph activity can create additional work
```

This replaces test/application code that manually waits in presumed
topological order.

The execution-mode end-to-end checkpoint validates the same graph under:

``` text
INLINE      PASS
ASYNC       PASS
PERSISTENT  PASS
default INLINE PASS
PROJECT quiescence PASS
```

## 13. Compiler error philosophy

The compiler should reject ambiguous or unsupported semantics early.

Examples:

-   invalid indentation;
-   missing PROJECT NAME/VERSION;
-   unknown object type;
-   missing required instance field;
-   invalid field value;
-   unknown port;
-   out-of-range dynamic port;
-   output→output or input→input connection;
-   plane mismatch;
-   incompatible type;
-   missing required worker;
-   unreadable worker source;
-   worker syntax error;
-   unsupported execution mode;
-   unresolved linkage mode;
-   feature dependency error.

A compiler error is preferable to a generated MACHINE whose runtime
semantics differ silently from PROJECT intent.

## 14. Compiler versus runtime dependencies

Compile time may depend on tools such as `jq` because JSON descriptors
are compiler inputs.

The generated MACHINE must not depend on `jq` merely because the
compiler used JSON.

This separation is essential:

``` text
JSON descriptors + jq
        compile time only
              │
              ▼
        canonical IR
              │
              ▼
      standalone Bash
```

## 15. Current and planned authority model

Future control-plane compilation must preserve two roles.

### ORCHESTRATOR

PROJECT-level logical authority:

-   topology rewiring;
-   object-variable mutation;
-   controlled code execution;
-   worker replacement;
-   logical reconfiguration.

### SCHEDULER

Per-MACHINE resource/placement authority:

-   migration admission;
-   memory reserve/release;
-   BLANK accounting;
-   ANT lending/borrowing;
-   placement/resource negotiation.

A distributed PROJECT is expected to have a scheduler on each MACHINE.
Compiler work should account for this model from the beginning rather
than later converting a single-central-scheduler design.

## 16. Development invariants

The compiler should preserve these invariants:

1.  PROJECT is source; MACHINE is executable realization.
2.  Parser syntax and descriptor semantics remain separated.
3.  Compiler modules load through `library.sh`.
4.  JSON descriptors are compile-time authorities.
5.  Feature closure is data-driven.
6.  Worker linkage and execution mode are independent.
7.  Every DATA operation preserves port identity.
8.  Local DATA is direct unless a real process/machine boundary requires
    another transport.
9.  FIFO is child→parent/control, not the normal DATA graph bus.
10. Parent owns canonical mutable state across Bash process boundaries.
11. Runtime metafunctions remain the executable construction substrate.
12. The generated inline MACHINE is standalone.
13. PROJECT-wide completion uses quiescence, not sleeps or hand-written
    object wait ordering.
