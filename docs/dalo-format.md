# DALO PROJECT Format (`.dalo`)

## Status

This document specifies the current human-readable DALO PROJECT source
format used by the compiler. It describes the syntax and semantic model
that are already part of the current compiler checkpoint and separately
identifies declarations that are architectural reservations for later
distributed/resource stages.

A `.dalo` file is **PROJECT source**, not a shell script and not a
serialized MACHINE.

``` text
PROJECT source (.dalo)
        │
        ▼
      daloc
        │
        ▼
standalone Bash MACHINE
```

## 1. Lexical structure

DALO source is indentation-sensitive.

Current structural indentation uses literal TAB characters:

``` text
PROJECT
<TAB>NAME example
<TAB>VERSION 1.0
```

Object members use one TAB. Members of a nested `WORKER` block use two
TABs.

Spaces must not be silently treated as equivalent structural
indentation. This is intentional: the parser should reject ambiguous
source rather than infer nesting from visually similar whitespace.

Blank lines may be used to separate logical sections.

Keywords are uppercase in the canonical format.

## 2. Mandatory PROJECT header

Every current PROJECT begins with:

``` text
PROJECT
    NAME <name>
    VERSION <major>.<minor>
```

Example:

``` text
PROJECT
    NAME hello
    VERSION 1.0
```

`NAME` determines the output MACHINE filename:

``` text
hello.dalo.bash
```

The current version syntax is:

``` text
^[0-9]+\.[0-9]+$
```

The PROJECT header is metadata for the complete logical program. It is
not an OBJECT.

## 3. OBJECT declarations

An object is declared by name:

``` text
OBJECT pipe1
    TYPE PIPE
```

The object name identifies the PROJECT instance. `TYPE` selects an
Object Definition ABI descriptor from `definitions/objects/`.

Conceptually:

``` text
Object Definition JSON
        │
        ▼
OBJECT instance in PROJECT
        │
        ├── instance fields
        ├── worker linkage
        └── graph connections
```

The parser accepts generic uppercase object fields. Their legality is
not hard-coded into the parser; the selected JSON object descriptor
defines valid instance fields and constraints.

This is a deliberate design rule:

> Syntax recognizes fields; descriptors define object semantics.

## 4. Instance fields

Object descriptors may declare `instance_fields`.

A COLUMN is the canonical example:

``` text
OBJECT col1
    TYPE COLUMN
    INPUTS 3
    OUTPUTS 4
    MAX_JOBS 8
```

The COLUMN descriptor defines required and optional fields and numeric
constraints. Current semantics include:

-   `INPUTS`: positive number of logical input ports;
-   `OUTPUTS`: positive number of logical output ports;
-   `MAX_JOBS`: optional positive job-pool/resource limit.

The compiler validates the values against the descriptor rather than
embedding COLUMN-specific field rules in the parser.

## 5. Ports

Fixed object types may declare explicit ports in their descriptor.

Dynamic object types may declare bounded `port_patterns`.

COLUMN uses dynamic ports conceptually equivalent to:

``` text
in1 ... inN
out1 ... outM
```

where `N` is `INPUTS` and `M` is `OUTPUTS`.

The descriptor can express a regex, direction, plane, type, captured
numeric index, and a field that bounds that index.

Therefore:

``` text
OBJECT col1
    TYPE COLUMN
    INPUTS 2
    OUTPUTS 3
```

accepts:

``` text
col1.in1
col1.in2
col1.out1
col1.out2
col1.out3
```

but must reject an out-of-range port such as `col1.in3` or `col1.out4`.

Port validation is compiler-side.

## 6. Every OBJECT has worker capability

The current architecture treats worker capability as a property of every
object type, including structural objects.

Object descriptors are the source of truth for feature requirements. For
T, Y, BIFURCATOR, and COLUMN the current intended feature set includes:

``` json
"features": ["core", "data", "worker", "structural"]
```

with worker requirements expressed by the descriptor.

The compiler must not infer worker capability from hard-coded type
names.

## 7. Nested WORKER block

A PROJECT can attach worker implementation information to an object:

``` text
OBJECT pipe1
    TYPE COLUMN
    INPUTS 2
    OUTPUTS 3
    MAX_JOBS 8

    WORKER
        CODE workers/pipe1.bash
        TYPE inline
        EXECUTION ASYNC
```

The WORKER block deliberately separates two independent axes.

### 7.1 `CODE`

``` text
CODE <path>
```

Identifies worker source/artifact relative to the PROJECT source
location unless a future definition explicitly changes resolution rules.

The compiler validates that required worker code exists and that Bash
worker source is syntactically valid before linking it.

### 7.2 `TYPE`

``` text
TYPE inline
```

`TYPE` describes **how worker code is linked**.

Current canonical distinction:

``` text
inline     worker code is physically embedded in the standalone MACHINE
include    reserved/parsed linkage form for external library-style loading
```

The current standalone linker intentionally rejects unresolved `include`
semantics rather than silently producing a MACHINE that is not actually
standalone.

`TYPE` must not be overloaded with execution policy.

### 7.3 `EXECUTION`

``` text
EXECUTION INLINE
EXECUTION ASYNC
EXECUTION PERSISTENT
```

`EXECUTION` describes **how the worker runs**.

If omitted, the current default is:

``` text
INLINE
```

The selected mode must be allowed by the object's descriptor.

The distinction is fundamental:

``` text
TYPE       = linkage
EXECUTION  = runtime execution mode
```

## 8. Execution semantics

### INLINE

The worker executes in the owning Bash context. Local DATA propagation
remains direct.

### ASYNC

A job executes in a child process. The parent remains owner of canonical
state. Child→parent completion/state reconciliation uses the object's
FIFO control/return channel.

### PERSISTENT

Long-lived child workers are retained across jobs.

Current invariant:

``` text
parent → persistent child DATA    DIRECT process channel
child → parent                    per-OBJECT FIFO
control                           per-OBJECT FIFO
```

The object FIFO is not a parent→child DATA queue.

## 9. DATA vectors

The canonical port-aware DATA representation is:

``` text
INPUT_DATA_VECTOR["<slot>|<input-port>"]
OUTPUT_DATA_VECTOR["<slot>|<output-port>"]
```

Incoming DATA is associated with the exact input port that received it.
Worker output is associated with the exact output port that produced it.

The public worker invocation ABI is port-aware:

``` bash
object_summon_worker input_port DATA...
```

Port identity must not be discarded by aliases or scalar shortcuts.

## 10. CONNECT

A logical edge connects an output port to an input port.

The compiler validates:

-   both object instances exist;
-   both ports exist for those instances;
-   source direction is output;
-   destination direction is input;
-   DATA/CONTROL planes match;
-   declared types are compatible.

The compiler lowers logical connection syntax into canonical EDGE
records. The generated MACHINE does not need to retain the original
source spelling.

## 11. `VIA`

`VIA` expresses an intermediate object/port while preserving a
human-readable topology description.

Example:

``` text
CONNECT origin1.out VIA T1.out1 pipe1.in
```

lowers conceptually to:

``` text
origin1.out → T1.in
T1.out1     → pipe1.in
```

For Y:

``` text
CONNECT pipe1.out VIA Y1.in1 endpoint1.in
```

becomes:

``` text
pipe1.out → Y1.in1
Y1.out    → endpoint1.in
```

For a two-port pass-through object such as PIPE:

``` text
CONNECT T1.out1 VIA pipe1 Y1.in1
```

becomes:

``` text
T1.out1   → pipe1.in
pipe1.out → Y1.in1
```

The canonical compiler representation is EDGE-based. `CONNECT`/`VIA` is
PROJECT syntax.

Chained VIA expressions are an intended language capability, but
implementations must validate actual parser/lowering support before
relying on arbitrarily long adjacent VIA chains.

## 12. COLUMN

COLUMN is the generalized N-input/M-output worker object.

``` text
OBJECT transform
    TYPE COLUMN
    INPUTS 4
    OUTPUTS 2
    MAX_JOBS 8
```

COLUMN does not assign application meaning to those ports. The worker
owns the transformation semantics.

Conceptual flow:

``` text
EDGE
  ↓
INPUT_DATA_VECTOR["slot|inN"]
  ↓
worker
  ↓
OUTPUT_DATA_VECTOR["slot|outM"]
  ↓
EDGE
  ↓
destination_summon_worker inK DATA
```

T, Y, and BIFURCATOR remain useful semantic/convenience object types
even where a sufficiently general COLUMN could reproduce their shape.

## 13. PROJECT quiescence

A compiled MACHINE provides PROJECT-level waiting semantics in addition
to object-local job-pool waits.

These are different contracts:

``` text
OBJECT job_pool_wait
    wait for work accepted by that object

PROJECT wait
    wait until graph activity reaches quiescence
```

PROJECT wait repeatedly reconciles child→parent activity and downstream
work until the complete relevant graph is idle. This avoids requiring
PROJECT users to manually wait in graph order:

``` text
src_wait
mid_wait
sink_wait
```

Such manual ordering is incorrect when upstream completion can create
downstream work after a downstream object was previously observed idle.

## 14. Feature resolution

Object descriptors declare features. Feature descriptors declare
dependencies.

Current Feature Definition ABI v1 examples:

``` json
{"abi":1,"name":"core","requires":[]}
{"abi":1,"name":"data","requires":["core"]}
{"abi":1,"name":"worker","requires":["data"]}
{"abi":1,"name":"structural","requires":["data"]}
```

The compiler computes dependency closure from JSON. It must not
hard-code rules such as "T implies worker."

This allows descriptor changes to change required feature closure
without parser changes.

## 15. Resource declarations: architectural PROJECT syntax

The following forms are part of the current architectural direction for
the resource/distributed stages and should be treated as reserved until
the corresponding compiler/runtime path is declared complete.

### `RESERVE_MEMORY`

``` text
RESERVE_MEMORY 512 M
```

Represents PROJECT-level BLANK capacity/headroom.

Key principle:

> BLANK is capacity, not absence.

### `ALLOW_REMOTE_ANTS`

``` text
ALLOW_REMOTE_ANTS
    COUNT 8
    CACHE ON
```

Allows remote ANTs to use local host capacity subject to scheduler
admission. `CACHE ON` is the intended default.

### `ALLOW_ANTS_REMOTE_EXEC`

``` text
ALLOW_ANTS_REMOTE_EXEC
```

Allows local PROJECT ANTs to execute remotely.

The directions are distinct:

``` text
ALLOW_REMOTE_ANTS       remote → local
ALLOW_ANTS_REMOTE_EXEC  local → remote
```

## 16. ORCHESTRATOR and SCHEDULER roles

The architecture distinguishes two control authorities.

### PROJECT ORCHESTRATOR

PROJECT-level logical control:

-   runtime topology changes;
-   input/output rewiring;
-   object-variable mutation;
-   controlled code execution;
-   worker replacement;
-   PROJECT-level behavioral reconfiguration.

### per-MACHINE SCHEDULER

Physical/resource control:

-   migration admission;
-   ANT lending/borrowing;
-   BLANK/resource accounting;
-   memory reservation/release;
-   local placement/resource decisions;
-   MACHINE-to-MACHINE resource negotiation.

Distributed PROJECTs are designed with a scheduler on every MACHINE. The
ORCHESTRATOR is a PROJECT-level logical authority and does not replace
per-MACHINE scheduling.

Exact `.dalo` declaration syntax for these system objects should be
finalized with their compiler descriptors rather than guessed by the
parser.

## 17. Complete current-style example

``` text
PROJECT
    NAME column_demo
    VERSION 1.0

OBJECT src
    TYPE COLUMN
    INPUTS 1
    OUTPUTS 2
    MAX_JOBS 4

    WORKER
        CODE workers/src.bash
        TYPE inline
        EXECUTION INLINE

OBJECT mid
    TYPE COLUMN
    INPUTS 2
    OUTPUTS 3
    MAX_JOBS 8

    WORKER
        CODE workers/mid.bash
        TYPE inline
        EXECUTION ASYNC

OBJECT sink
    TYPE COLUMN
    INPUTS 1
    OUTPUTS 1
    MAX_JOBS 2

    WORKER
        CODE workers/sink.bash
        TYPE inline
        EXECUTION PERSISTENT

CONNECT src.out2 mid.in2
CONNECT mid.out3 sink.in1
```

Compilation:

``` bash
./compiler/daloc.bash path/to/column_demo.dalo
```

Output:

``` text
path/to/column_demo.dalo.bash
```

The generated MACHINE embeds the linked worker code and required runtime
implementation so that the standalone artifact does not need compiler
JSON descriptors or `jq` at runtime.

## 18. Format design rules

The format follows several long-term rules:

1.  PROJECT syntax describes logical intent, not Bash implementation
    details.
2.  JSON descriptors are the semantic authority for object fields,
    ports, features, and allowed execution modes.
3.  Worker linkage and worker execution are independent.
4.  DATA always retains port identity.
5.  FIFO is not the default DATA graph transport.
6.  The compiler lowers source syntax to canonical IR/EDGE structures
    before MACHINE linking.
7.  Unsupported semantics must be rejected explicitly rather than
    silently approximated.
8.  Distributed/resource syntax must preserve the ORCHESTRATOR/SCHEDULER
    authority split.
