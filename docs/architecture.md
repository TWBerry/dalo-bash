# DALO for Bash --- Architecture

> **Distributed Asynchronous Library with Objects for Bash**
>
> Architecture of the PROJECT language, compiler, standalone MACHINE
> runtime, object model, DATA and CONTROL planes, worker execution,
> metaprogramming, migration, resources, and distributed control.

## 1. Mission

DALO is an object-oriented asynchronous/distributed execution framework
implemented in Bash. Its purpose is not to imitate ordinary Unix
pipelines. DALO models a system as a graph of typed objects with
explicit ports, workers, execution modes, identity, resource ownership,
and control boundaries.

The editable representation is a **PROJECT**. The compiler lowers the
PROJECT into a standalone executable **MACHINE**.

``` text
human-readable PROJECT
      project.dalo
           │
           ▼
       DALO compiler
           │
   definitions + IR
           │
           ▼
 <name>.dalo.bash
           │
           ▼
 executable MACHINE
```

DALO is a standalone project. Its architecture is intentionally general
rather than tied to another operating system or runtime project.

## 2. Core invariants

The following rules define the architecture more strongly than any
individual implementation function.

### 2.1 PROJECT is not MACHINE

PROJECT describes logical intent:

-   object instances and types;
-   ports and graph connections;
-   worker implementation selection;
-   execution modes;
-   object instance fields;
-   resource declarations;
-   future placement/distribution policy;
-   PROJECT metadata.

MACHINE is the executable realization:

-   runtime namespaces;
-   specialized Bash functions;
-   linked worker code;
-   canonical routing;
-   process boundaries;
-   queues/direct channels;
-   FIFO control endpoints;
-   resource bindings;
-   minimum runtime support.

A PROJECT may remain logically unchanged while the compiler changes its
physical realization.

### 2.2 DATA and CONTROL are separate planes

**DATA** is application payload moving through object ports.

**CONTROL** changes runtime/object behavior, ownership-sensitive state,
lifecycle, topology, code, scheduling, migration, or resources.

The distinction is deliberate:

``` text
DATA plane                       CONTROL plane

port-aware payload              commands/events/mutations
INPUT/OUTPUT_DATA_VECTOR        per-OBJECT FIFO
canonical EDGE routing          parent canonical state
summon_worker                   orchestration/scheduling
```

FIFO is not the default local DATA graph bus.

### 2.3 Process boundaries determine transport

Canonical direction:

``` text
same Bash context          DIRECT
parent → persistent child  DIRECT process channel
child → parent             per-OBJECT FIFO
local OBJECT → OBJECT DATA DIRECT/port-aware routing
different MACHINE          BRIDGE/network transport
```

A transport exists because a real ownership/process/machine boundary
requires it, not because every logical edge should look like a Unix
pipe.

### 2.4 Parent owns canonical state

A Bash child receives a copy of parent shell state. It cannot directly
mutate canonical parent arrays/variables.

Therefore the owning parent shell is authoritative for:

-   task state;
-   slot ownership;
-   worker PID bookkeeping;
-   canonical object variables;
-   DATA vectors;
-   lifecycle;
-   completion/retry state;
-   migration state.

Children return results/control to the parent through the object's FIFO
boundary.

## 3. Metaprogramming model

DALO uses Bash as implementation language and code-generation language.

### 3.1 Namespace specialization

Each runtime object receives a namespace. Metafunctions generate
concrete Bash symbols specialized for that namespace.

Conceptually:

``` text
M_obj_summon_worker
M_obj_on_job_completed
M_obj_TASK_*
M_obj_SLOT_*
M_obj_INPUT_DATA_VECTOR
M_obj_OUTPUT_DATA_VECTOR
M_obj_VARIABLE_TYPE
M_obj_VARIABLE_VALUE
```

This avoids repeated generic namespace dispatch on hot paths.

### 3.2 Metafunctions are architectural

A `Make_*`-style component generates code that is both:

1.  installed into the live shell;
2.  recorded as canonical object code.

``` text
feature/metafunction template
       │
       ├── specialize + eval ──► live MACHINE function
       │
       └── record source ──────► reconstruction/migration image
```

DALO must not remove metafunctions merely to make the source look more
conventional. They are the bridge between selective compilation and
reconstructable runtime objects.

### 3.3 Canonical code image

Generated components are recorded in deterministic order under
`code.*`-style storage and aggregated into `${ns}_variables_code`.

The same conceptual code image can support:

-   object construction;
-   standalone MACHINE linking;
-   runtime reconstruction;
-   migration.

### 3.4 Optimization principle

DALO optimizes by **omitting unneeded features**, not by replacing
specialized object code with generic runtime wrappers.

Global stateless helpers may be shared. Stateful object mechanisms
normally remain namespaced and specialized.

## 4. Object model

DALO separates:

``` text
OBJECT TYPE DEFINITION
        │
        ▼
OBJECT INSTANCE
        │
        ▼
WORKER IMPLEMENTATION
```

### 4.1 Object Definition ABI v1

Compiler-side JSON descriptors define:

-   ABI version;
-   object type/name;
-   fixed ports;
-   dynamic bounded port patterns;
-   port direction;
-   DATA/CONTROL plane;
-   port type;
-   instance fields;
-   methods;
-   feature requirements;
-   worker requirement;
-   allowed execution modes.

Descriptors are compile-time semantic authorities and are not copied
wholesale into the MACHINE.

### 4.2 Current object families

The architecture includes fixed structural/endpoint-style types such as
ORIGIN, PIPE, ENDPOINT, T, Y, BIFURCATOR and the generalized COLUMN
type.

All objects have worker capability. The compiler derives this from
descriptors/features rather than hard-coded type names.

### 4.3 COLUMN

COLUMN is a generalized N-input/M-output worker object.

``` text
OBJECT col1
    TYPE COLUMN
    INPUTS 3
    OUTPUTS 4
    MAX_JOBS 8
```

Ports are bounded by instance fields:

``` text
in1 ... in3
out1 ... out4
```

The worker owns the N→M transformation semantics. Runtime routing does
not interpret application payload meaning.

### 4.4 T, Y, BIFURCATOR

These remain useful semantic/convenience object types even when a
general COLUMN could reproduce a similar port shape. Structural identity
is useful to PROJECT authors, compiler policy, diagnostics, and future
visualization.

## 5. Port-aware DATA ABI

DALO does not allow DATA to lose its port identity.

Canonical vectors:

``` text
INPUT_DATA_VECTOR["slot|input-port"]
OUTPUT_DATA_VECTOR["slot|output-port"]
```

Public invocation:

``` bash
object_summon_worker input_port DATA...
```

Generic routing:

``` text
source OUTPUT_DATA_VECTOR["slot|outN"]
        │
        ▼
canonical EDGE
        │
        ▼
destination_summon_worker inM DATA
```

Legacy scalar aliases that erase port identity are incompatible with
this model.

## 6. Graph and routing

PROJECT source uses CONNECT/VIA syntax. The compiler lowers it into
canonical EDGE records.

The runtime graph should use generic routing rather than
object-type-specific T/Y forwarding hooks.

This is important for dynamic reconfiguration: specialized routing
machinery can be generated once while concrete route state remains
mutable.

Future ORCHESTRATOR operations can therefore change:

``` text
A.out2 → B.in1
```

to:

``` text
A.out2 → C.in4
```

without changing the DATA ABI.

## 7. Worker linkage and execution are independent

A WORKER block has two distinct dimensions.

``` text
TYPE       inline | include
EXECUTION  INLINE | ASYNC | PERSISTENT
```

`TYPE` controls how implementation code is linked.

`EXECUTION` controls how it runs.

The current default execution mode is INLINE.

Conflating these concepts would prevent combinations such as embedded
code executed persistently.

## 8. Execution modes

### 8.1 INLINE

Worker executes in the owning shell.

``` text
DATA vector
    │
    ▼
worker()
    │
    ▼
completion/routing
```

No process boundary is crossed.

### 8.2 ASYNC

A job executes in a child process.

``` text
parent canonical state
       │
       ├── spawn child / provide DATA
       │
       ▼
     worker
       │
       └── child→parent FIFO
                    │
                    ▼
          canonical completion
                    │
                    ▼
             downstream DATA
```

### 8.3 PERSISTENT

Long-lived children amortize process startup cost.

Canonical transport split:

``` text
parent ── DIRECT DATA ──► persistent child
parent ◄── per-OBJECT FIFO ─ child result/control
```

The per-object FIFO must not be repurposed as the parent→child DATA
queue.

### 8.4 Current execution-mode checkpoint

The same compiled graph has been runtime-validated under:

``` text
INLINE      PASS
ASYNC       PASS
PERSISTENT  PASS
```

The default execution mode has also been validated as INLINE.

## 9. FIFO control/return channel

Every object has a per-object FIFO control endpoint.

The FIFO has two central roles:

1.  **child → parent** communication across Bash copy-on-fork semantics;
2.  **CONTROL-plane** communication addressed to the object.

It is not the normal DATA graph transport.

### 9.1 Single consumer, multiple producers

Canonical topology:

``` text
worker B1 ─┐
worker B2 ─┤
OBJECT A ──┼──► FIFO_B ──► parent/object dispatcher B
OBJECT C ──┘
```

The FIFO has one canonical consumer: the owning parent/object
dispatcher. Multiple producers may send frames to it.

Workers should not compete as independent consumers of the same object
FIFO.

### 9.2 Horizontal control

An authorized object or system authority can address another object's
FIFO. The receiving object's dispatcher performs the canonical mutation.

This supports future operations such as:

``` text
SET_VAR
EXEC
REPLACE_WORKER
CONNECT_OUT
CONNECT_IN
DISCONNECT_OUT
DISCONNECT_IN
lifecycle/migration operations
```

The sender requests a mutation; the receiving object's canonical owner
performs it.

### 9.3 Frame protocol

The runtime already uses a line-oriented framed protocol with Bash `%q`
argument encoding and tags for output/mutation/RPC/code operations.

A frame conceptually contains:

``` text
<tag> TAB <argc> TAB <arg1:%q> ... <argN:%q>
```

The protocol must remain within atomic-write constraints when multiple
producers share one FIFO. A dedicated FIFO Control ABI/stress phase is
planned to formalize request identity, ACK/error behavior, concurrent
writers, framing, shutdown, and failure cases.

Encoding is not authentication.

## 10. Object-local wait versus PROJECT quiescence

An object can become locally idle while its upstream object has not yet
delivered future work.

Therefore:

``` text
OBJECT job_pool_wait
    waits for work already accepted by that object

PROJECT wait
    waits for graph-wide quiescence
```

PROJECT quiescence repeatedly:

-   drains/reconciles child→parent channels;
-   processes completions;
-   permits completion hooks to generate downstream DATA;
-   checks pending/in-flight work;
-   repeats until no further work is produced.

This is cleaner and more correct than requiring callers to know graph
order.

## 11. Feature Definition ABI v1

Feature descriptors are JSON compile-time data.

Current core examples:

``` text
core        requires []
data        requires [core]
worker      requires [data]
structural  requires [data]
```

Object descriptors list features. The compiler resolves transitive
closure.

This has been tested as data-driven behavior: changing an object's
descriptor feature list changes its resolved closure without adding
compiler type-specific inference.

## 12. Selective construction/linking

Feature closure drives which construction components are needed.

The intended optimization model:

``` text
descriptor features
       │
       ▼
feature closure
       │
       ▼
selected Make_* components
       │
       ▼
namespace-specialized object
```

The runtime can therefore preserve specialized functions while the
compiler avoids linking unrelated capabilities.

## 13. Standalone MACHINE

The compiler links PROJECT source into `<NAME>.dalo.bash`.

For inline worker linkage, the MACHINE is intended to execute without:

-   compiler modules;
-   JSON descriptors;
-   `jq`;
-   original embedded worker source files;
-   repository-relative runtime files.

The current end-to-end compiler checkpoint has validated isolated
execution of a generated MACHINE.

## 14. Identity

DALO distinguishes stable identity from physical runtime handles.

``` text
UUID
  │ stable across migration
  ▼
obj_id
  │ current routable identity
  ▼
ns
  │ local Bash symbol namespace
  ├── FIFO  local control/return endpoint
  └── FD    physical local handle
```

UUID is semantic identity. File descriptors and local FIFO paths are not
migratable identity.

## 15. Migration

Migration uses canonical ownership and quiescence rather than
`SIGSTOP`-style process freezing.

Intended lifecycle:

``` text
request
  ↓
close admission
  ↓
wait/quiesce
  ↓
drain/reconcile FIFO
  ↓
pending == 0
  ↓
diagnose/validate
  ↓
snapshot canonical state + code
  ↓
destination creates fresh runtime identity/ns
  ↓
restore same UUID
  ↓
hydrate
  ↓
validate
  ↓
routing cutover
```

The same quiescing discipline is reusable for structural operations such
as safe worker replacement or topology mutation when an operation
requires a stable boundary.

### Migratable image versus migration runtime

Every object may have a reconstructable canonical image without every
MACHINE carrying the full migration-control subsystem.

Selective compilation should distinguish representation from optional
migration machinery.

## 16. Resources and BLANK

DALO treats BLANK as capacity:

> **BLANK is capacity, not absence.**

A BLANK can represent available/reserved capacity before a concrete
external resource is bound.

Physical handles such as file descriptors are machine-local and must be
recreated/rebound after migration. Semantic state may migrate; raw
physical handles generally do not.

## 17. ANT borrowing versus migration

Borrowing remote execution capacity is distinct from migrating an
object.

HOME owns:

-   canonical task identity/state;
-   worker semantics/artifact;
-   input DATA;
-   retry policy;
-   result/completion decision.

HOST owns:

-   physical ANT/worker process;
-   admitted CPU/memory/resource capacity;
-   lease lifetime;
-   physical slot/process state.

Therefore:

> Borrowing execution is not object migration.

The task can execute elsewhere while canonical ownership remains HOME.

## 18. ORCHESTRATOR and SCHEDULER

DALO separates logical PROJECT control from physical MACHINE resource
control.

### 18.1 ORCHESTRATOR

PROJECT-level authority for:

-   runtime topology;
-   in/out rewiring;
-   arbitrary authorized object-variable mutation;
-   controlled code execution;
-   worker replacement;
-   logical PROJECT reconfiguration.

The ORCHESTRATOR can use object FIFO control endpoints to request
canonical mutations.

### 18.2 SCHEDULER

Every MACHINE in a distributed PROJECT needs a scheduler because
resource decisions are local to the physical host/MACHINE.

Scheduler responsibilities include:

-   migration admission/permission;
-   ANT lending and borrowing;
-   memory reservation/release;
-   BLANK/resource accounting;
-   placement;
-   resource negotiation with other MACHINE schedulers.

This division prevents one central logical orchestrator from becoming
the authority for remote physical resource ownership.

## 19. Distributed structure

The structural model distinguishes local and global structure.

``` text
LOCAL_STRUCTURE
    MACHINE self
        OBJECT ...
        BLANK ...
        CONNECT ...
```

``` text
GLOBAL_STRUCTURE
    MACHINE A
        OBJECT ...
        BLANK ...
    MACHINE B
        OBJECT ...
        BLANK ...
    MACHINE_CONNECT ...
```

GLOBAL_STRUCTURE describes what exists where and how it is connected. It
is not a telemetry database.

Runtime resource/telemetry values are queried when decisions are made
rather than continuously embedded into structural identity.

## 20. Bridge and remote control boundary

Different MACHINEs communicate through a bridge/network layer.

DATA and CONTROL remain distinct.

Remote CONTROL must pass a capability/authority boundary before reaching
a local object's FIFO dispatcher. Local FIFO framing does not itself
provide cryptographic authentication.

Sender identity, target identity, capability, and requested operation
belong to the remote control model.

## 21. Compiler architecture

Current compiler pipeline:

``` text
.dalo
  ↓
parser
  ↓
IR
  ↓
definition validation
  ↓
CONNECT/VIA lowering
  ↓
feature closure
  ↓
runtime metafunction selection/specialization
  ↓
standalone MACHINE
```

Compiler modules use `runtime/library.sh` and `include`; they do not
directly source one another.

JSON descriptors are compile-time inputs. Runtime MACHINE execution
should not require `jq` merely because the compiler used JSON.

See `compiler.md` for the detailed compiler contract.

## 22. `.dalo` source model

Current mandatory metadata:

``` text
PROJECT
    NAME example
    VERSION 1.0
```

Objects are nested declarations:

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

Connections are logical PROJECT declarations:

``` text
CONNECT source.out1 pipe1.in2
CONNECT source.out2 VIA T1.out1 pipe2.in1
```

See `dalo-format.md` for the complete format specification.

## 23. Security and authority

DALO's control plane is intentionally powerful. An ORCHESTRATOR may
eventually be able to change arbitrary object variables, execute
controlled code, replace workers, and rewire topology.

Therefore authority is not optional architectural decoration.

Key distinctions:

-   local ownership is not remote network trust;
-   ordinary OBJECT authority is not automatically ORCHESTRATOR
    authority;
-   SCHEDULER resource authority is distinct from ORCHESTRATOR
    structural authority;
-   `%q` framing is encoding, not authentication;
-   BLANK capacity does not imply unrestricted authority over host
    resources.

The capability model must preserve these distinctions as distributed
control is implemented.

## 24. Current development checkpoint

The following major pieces are already established or runtime-validated:

-   dependency-aware DALO library loader;
-   canonical generated-code storage/metafunction model;
-   Object Definition ABI v1;
-   Feature Definition ABI v1 with JSON-driven closure;
-   compiler/runtime module separation;
-   canonical compiler IR;
-   CONNECT/VIA lowering checkpoint;
-   COLUMN bounded dynamic port ABI;
-   port-aware DATA vectors;
-   generic EDGE routing;
-   strict port-aware summon-worker ABI;
-   selective constructor/linker direction;
-   `.dalo` → standalone MACHINE end-to-end compilation;
-   worker linkage/execution separation;
-   INLINE/ASYNC/PERSISTENT execution-mode compilation;
-   PERSISTENT parent→child DIRECT DATA transport;
-   child→parent/per-object FIFO boundary;
-   PROJECT-level quiescence wait.

The next control-plane work should formalize and stress-test the FIFO
Control ABI before building richer ORCHESTRATOR/SCHEDULER commands on
top of it.

## 25. Architectural summary

DALO can be reduced to a small set of strong ideas:

``` text
PROJECT describes intent.
MACHINE executes realization.

OBJECT owns canonical state.
WORKER performs computation.

DATA is port-aware and direct where possible.
FIFO crosses child→parent/control boundaries.

Metafunctions specialize runtime code.
Feature closure decides what gets linked.

PROJECT wait establishes graph quiescence.
Migration reuses canonical state and quiescing.

ORCHESTRATOR controls logical structure.
SCHEDULER controls per-MACHINE resources.

Distributed execution does not erase ownership.
```

These invariants should remain stable even as individual runtime
functions, object descriptors, and compiler passes evolve.
