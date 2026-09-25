# DALO for Bash --- Architecture

> **Distributed Asynchronous Library with Objects for Bash**\
> Architecture and implementation model of the DALO runtime, compiler
> substrate, object model, process boundaries, migration, distributed
> execution, and metaprogramming system.

## 1. Purpose

DALO is an object-based framework for **modeling complex systems** and
constructing **advanced asynchronous and distributed pipelines in
Bash**.

A DALO program is not intended to be merely a collection of shell
functions connected by pipes. The design models a system as a graph of
typed objects with explicit ports, execution modes, worker
implementations, resources, identities, and transport boundaries. The
editable model is a **PROJECT**; compilation lowers that model into a
standalone executable **MACHINE**.

``` text
          human-readable model
                project.dalo
                     │
                     ▼
              DALO compiler
                     │
          object / worker / feature
             definition resolution
                     │
                     ▼
             async_script.bash
                     │
                     ▼
             executable MACHINE
```

The long-term compiler goal is that the generated MACHINE contains only
the runtime capabilities actually required by its objects.

------------------------------------------------------------------------

## 2. Architectural principles

DALO is built around several rules that are more important than any
individual function.

### 2.1 PROJECT is not MACHINE

**PROJECT** is the editable source representation. It describes the
logical system:

-   object declarations and object types,
-   object positions in the modeling field,
-   logical edges and ports,
-   workers and worker-count policy,
-   execution modes,
-   resources,
-   parameters,
-   placement constraints and future compiler/JIT hints.

**MACHINE** is the executable realization of that model. Compilation
produces a standalone Bash program, conventionally `async_script.bash`.

The PROJECT can remain unchanged while the compiler chooses a different
physical realization.

``` text
PROJECT                         MACHINE

logical objects                runtime object instances
logical edges                  direct calls / FIFO boundaries / bridges
worker declarations     --->   executable worker code
placement constraints          concrete placement
editor metadata                normally omitted
```

This separation is essential for future optimization, migration, and
distributed placement.

### 2.2 DATA and CONTROL are separate planes

DALO deliberately distinguishes **DATA flow** from **CONTROL flow**.

DATA is the payload moving through the modeled pipeline. CONTROL is used
for ownership-sensitive mutations, RPC-like operations, lifecycle
events, migration operations, and distributed control.

A local DATA edge should not automatically become a FIFO operation. For
objects owned by the same Bash process, the preferred transport is a
**direct Bash function call**.

### 2.3 Process boundaries determine transport

The central rule is:

``` text
same Bash context       → DIRECT
child/subshell → parent → FIFO
parent → worker         → worker input / queue
different MACHINE       → BRIDGE / TCP
```

FIFO therefore exists primarily because of Bash process semantics, not
because DALO wants to imitate Unix pipelines internally.

### 2.4 Canonical state has one owner

A child Bash process receives a copy of its parent's shell state.
Mutating arrays or variables in the child does **not** mutate the
canonical parent state.

DALO therefore treats the owning parent shell as the authority for state
such as task tables, worker slots, PIDs, object variables, and lifecycle
state. Children return mutations and results to the owner instead of
pretending that inherited shell state is shared memory.

------------------------------------------------------------------------

# 3. Metaprogramming is the core implementation technique

DALO uses Bash as both the implementation language and a
**code-generation language**.

This is one of the most important architectural characteristics of the
project.

## 3.1 Namespace-specialized code generation

Each runtime object has a namespace (`ns`). Runtime methods and state
are generated with that namespace embedded directly into their Bash
symbols.

Conceptually:

``` text
m_0003_pipe_summon_worker
m_0003_pipe_on_job_completed
m_0003_pipe_TASK_*
m_0003_pipe_SLOT_*
m_0003_pipe_WORKER_PIDS
m_0003_pipe_VARIABLE_TYPE
m_0003_pipe_VARIABLE_VALUE
```

Generator functions construct Bash source, validate it, evaluate it into
the current shell, and record the generated source as part of the
object's code image.

This gives DALO a form of **static specialization inside a dynamic shell
language**.

Instead of routing every operation through a generic function such as:

``` text
generic_summon_worker "$ns" ...
```

the generated object can call:

``` text
m_0003_pipe_summon_worker ...
```

directly.

That avoids repeated namespace lookup, nameref setup, indirect
expansion, and generic dispatch on hot paths.

## 3.2 Code as object data

The runtime contains canonical variable/code storage. Generated
components are stored under protected `code.*` entries and aggregated
into:

``` text
${ns}_variables_code
```

The important mechanism is:

``` text
generator
   │
   ├── creates Bash source
   │
   ├── bash -n validation
   │
   ├── eval into current runtime
   │
   └── record source as code.<component>
                     │
                     ▼
             ${ns}_variables_code
```

This makes generated behavior representable as data. The same conceptual
object image can therefore become useful to both **compilation** and
**migration**.

DALO also supports validated runtime code application. Code is
syntax-checked before evaluation, recorded as another code component,
and the resulting aggregate object code can be validated again.

## 3.3 Generator families

The current runtime demonstrates the pattern through generators for:

-   variable APIs,
-   FIFO APIs,
-   synchronous iterators,
-   asynchronous iterators,
-   recursive traversal,
-   worker/lifecycle methods,
-   task/job-pool machinery,
-   object-specific runtime methods.

For example, iterator generators create specialized functions whose
local variable names and target arrays are known when the function is
generated.

This is deliberate metaprogramming rather than incidental use of `eval`.

## 3.4 Why namespaced runtime code is not aggressively deduplicated

DALO should **not** deduplicate stateful namespaced runtime functions
merely to reduce source size if doing so replaces static specialization
with runtime indirection.

The intended optimization is:

> **omit features an object does not need, rather than replacing
> specialized object code with generic wrappers.**

Truly global, stateless, namespace-independent helpers may be shared.
Object-state operations should normally remain specialized.

------------------------------------------------------------------------

# 4. Object model

DALO separates three concepts:

``` text
OBJECT TYPE DEFINITION
        │
        │ describes structure/capabilities
        ▼
OBJECT INSTANCE in PROJECT
        │
        │ selects concrete worker/configuration
        ▼
WORKER IMPLEMENTATION
```

## 4.1 Object Definition ABI v1

Object types are described by compiler-side JSON descriptors. They are
**not runtime state** and should not be copied wholesale into the
generated MACHINE.

A descriptor defines:

-   ABI version,
-   object type,
-   human-readable name,
-   ports,
-   port direction,
-   DATA or CONTROL plane,
-   port data type,
-   required methods,
-   base features,
-   worker requirement,
-   allowed execution modes.

The current formal descriptors are:

-   `ORIGIN`
-   `PIPE`
-   `ENDPOINT`
-   `T`
-   `Y`
-   `BIFURCATOR`

The compiler-side validator checks that connected ports exist, output
connects to input, planes match, and port types are compatible.

## 4.2 Structural objects

Structural objects describe topology, not application semantics.

### T

``` text
          ┌── out1
in ── T ──┤
          └── out2
```

One input is forwarded to two outputs.

### Y

``` text
in1 ──┐
      ├── Y ── out
in2 ──┘
```

Y provides two structural inputs and one output. Pairing, buffering,
fading, synchronization, or application-specific merge semantics should
not be silently built into the structural object; those belong in
worker/application behavior when required.

### BIFURCATOR

A bifurcator replicates an incoming DATA item to multiple outputs.

## 4.3 Worker-bearing objects

`ORIGIN`, `PIPE`, and `ENDPOINT` currently require workers and allow:

``` text
INLINE
ASYNC
PERSISTENT
```

Structural `T`, `Y`, and `BIFURCATOR` descriptors currently allow
`INLINE`.

------------------------------------------------------------------------

# 5. Execution modes

## 5.1 INLINE

INLINE executes the worker in the owning shell.

``` text
Object A
   │ direct call
   ▼
Worker
   │ direct completion
   ▼
Object B
```

This is the preferred local fast path because no process boundary has
been crossed.

## 5.2 ASYNC

ASYNC creates a child process for a job.

``` text
canonical parent
      │
      ├── spawn child
      │       │
      │       └── execute worker
      │                │
      │             result
      │                ▼
      ◄────────────── FIFO
      │
 canonical completion
      │
      ▼
direct DATA propagation
```

The FIFO is necessary because the child cannot mutate the parent's
canonical Bash state.

## 5.3 PERSISTENT

PERSISTENT uses long-lived child workers. It avoids creating a new
process for every item, but the ownership rule remains the same.

``` text
parent ── submit ──► persistent child
  ▲                       │
  │                       │ work
  │                       ▼
  └──────── FIFO ◄──── result
```

After the parent receives and canonicalizes the completion, ordinary
local graph propagation can again continue directly.

------------------------------------------------------------------------

# 6. FIFO: the child → parent bypass

The FIFO mechanism is one of DALO's most important Bash-specific
architectural solutions.

## 6.1 The Bash problem

After `fork`/subshell creation:

``` text
PARENT STATE
    │
    └── copied
          ▼
       CHILD STATE
```

The child can modify its copy, but the parent will never see those
modifications.

This is especially dangerous for:

-   task state,
-   slot ownership,
-   PID tracking,
-   object variables,
-   completion state,
-   retries,
-   lifecycle transitions.

DALO therefore **bypasses the impossible child→parent variable
relationship** by sending an explicit operation back to the canonical
parent through FIFO.

``` text
child wants canonical mutation
          │
          ▼
    encode FIFO frame
          │
          ▼
       FIFO write
          │
          ▼
 parent decodes frame
          │
          ▼
 parent performs mutation
```

The FIFO is effectively an ownership-boundary message channel.

## 6.2 FIFO Frame ABI v1

The runtime documents these frame tags:

``` text
O    worker output
S    canonical parent scalar mutation
A    canonical parent array append
C    parent/object RPC
X    parent-side code mutation
```

A frame is represented as one physical line:

``` text
<tag> TAB <argc> TAB <arg1:%q> TAB ... TAB <argN:%q>
```

Arguments use Bash `%q` encoding.

The frame is designed to fit in one atomic FIFO write budget. This
matters because multiple child writers must not interleave fragments of
logical messages.

## 6.3 FIFO is not the normal graph bus

A crucial rule:

> **FIFO is not the default local DATA transport.**

Using FIFO for every object-to-object edge would add serialization,
parsing, kernel crossings, and ownership complexity where a direct
function call is sufficient.

FIFO belongs at actual process/ownership boundaries.

------------------------------------------------------------------------

# 7. Tasks, workers, and canonical lifecycle state

Asynchronous execution requires the parent to own the authoritative task
model.

Conceptually:

``` text
TASK
 ├── task identity
 ├── attempt
 ├── state
 ├── arguments
 ├── timing
 └── completion

SLOT
 ├── worker/process association
 ├── task association
 └── lifecycle state
```

A completion from a child is not trusted as an implicit mutation of
shared state. The parent receives the event and reconciles it against
canonical task/slot information.

This is also the foundation required for retries, quiescing, migration,
diagnostics, and remote execution.

------------------------------------------------------------------------

# 8. Identity model

DALO distinguishes permanent identity from current runtime location.

## 8.1 UUID

The UUID is the stable identity of an object.

It is intended to survive migration.

## 8.2 obj_id

`obj_id` is the current routable runtime identity, conceptually tied to
the current MACHINE/script instance and local object identity.

It may change when an object moves.

## 8.3 ns

`ns` is the local Bash symbol namespace used for generated functions and
variables.

It is an implementation identity, not the permanent distributed
identity.

## 8.4 FIFO and FD

FIFO is the current local control endpoint.

File descriptors are physical runtime handles and are **not canonical
migratable identity**.

The resulting model is:

``` text
UUID        stable object identity
  │
  ▼
obj_id      current routable identity
  │
  ▼
ns          local Bash symbol namespace
  │
  ├── FIFO  local ownership/control endpoint
  └── FD    local physical runtime handle
```

A resolver maps stable identity to current routable identity.

------------------------------------------------------------------------

# 9. Migration

Migration is not simply "copy variables to another shell".

The intended lifecycle is:

``` text
migration request
      │
      ▼
close admission
      │
      ▼
wait for workers
      │
      ▼
drain / reconcile FIFO
      │
      ▼
pending == 0
      │
      ▼
diagnose / validate
      │
      ▼
snapshot canonical state + required code
      │
      ▼
destination creates fresh runtime identity/ns
      │
      ▼
restore SAME UUID
      │
      ▼
hydrate state/code
      │
      ▼
validate
      │
      ▼
routing cutover
```

The important distinction is between:

### MIGRATABLE IMAGE

Canonical state plus the code required to reconstruct the object.

This representation can conceptually exist for every object.

### MIGRATION RUNTIME

The machinery for requesting migration, quiescing, exporting, importing,
validating, and cutting over.

Only objects/MACHINEs that actually need runtime migration should be
forced to carry this machinery.

This distinction is important for future feature-based compilation.

## 9.1 Code and migration converge

Because DALO records generated object code in `code.*` and
`${ns}_variables_code`, the same code image can become the basis for:

``` text
object construction
       │
       ▼
canonical code image
       │
       ├──► compiler
       │       └──► MACHINE
       │
       └──► migration
               └──► destination object
```

This avoids maintaining two unrelated representations of "what an object
is".

------------------------------------------------------------------------

# 10. Worker borrowing and distributed resource exchange

DALO distinguishes **borrowing execution capacity** from **migrating an
object**.

A borrowed worker remains a physical resource owned by the remote host.
The task remains canonically owned by its HOME.

``` text
HOME MACHINE                         HOST MACHINE

canonical task
     │
     ├── resource query ───────────────►
     │◄──────────── resource reply ────┤
     │
     ├── lease request ────────────────►
     │◄──────────── lease grant ───────┤
     │
     ├── JOB + worker semantics ──────► borrowed ant/worker
     │                                      │
     │                                      ▼
     │                                  execution
     │                                      │
     │◄──────────────── RESULT ─────────────┘
     │
canonical completion
     │
     └── lease release ────────────────►
```

The resource protocol developed in the runtime uses concepts such as:

``` text
RESOURCE_QUERY
RESOURCE_REPLY
LEASE_REQUEST
LEASE_GRANT
LEASE_DENY
LEASE_RELEASE
LEASE_RELEASED
JOB
RESULT
ERROR
```

Resource accounting distinguishes worker capacity such as:

``` text
workers.total
workers.busy
workers.free
workers.offered
```

## 10.1 HOME ownership

HOME owns:

-   canonical task identity and state,
-   worker artifact/code semantics,
-   input DATA,
-   retries,
-   expected result,
-   completion decision.

## 10.2 HOST ownership

HOST owns:

-   the physical worker/ant process,
-   CPU/resource admission,
-   local limits,
-   lease lifetime,
-   physical slot/process state.

Therefore:

> **Borrowing a worker is not object migration.**

The computation travels; canonical object/task ownership does not.

## 10.3 Remote children do not own TCP

The same parent/child rule applies remotely.

A child process should not become the canonical owner of a shared
network connection merely because it performed the computation.

The safe shape is:

``` text
remote child
    │
    ▼
local HOST result handoff
    │
    ▼
HOST canonical parent
    │
    ▼
TCP
    │
    ▼
HOME canonical parent
```

This keeps socket ownership and protocol state out of transient child
processes.

------------------------------------------------------------------------

# 11. BRIDGE and cross-MACHINE edges

A logical edge that crosses MACHINE boundaries is lowered to a bridge
pair.

``` text
MACHINE A                              MACHINE B

Object A
   │
   │ DIRECT
   ▼
Bridge A
   │
   │ TCP
   ═════════════════════════════════► Bridge B
                                         │
                                         │ DIRECT
                                         ▼
                                      Object B
```

The receiving bridge is not intended to become a general-purpose router
for the whole graph. It can be compiled with a concrete local target.

DATA and CONTROL remain distinct.

Conceptually:

``` text
DATA:
BRIDGE  1  DATA  <payload>

CONTROL:
CTRL  <src>  <dst>  <capability>  <FIFO frame>
```

CONTROL received from TCP must pass the TCP capability gate before it is
allowed to reach the local control/FIFO mechanism.

------------------------------------------------------------------------

# 12. Capability boundary

Local ownership control and remote network control are not equivalent
trust domains.

A remote CONTROL operation therefore carries information such as:

-   sender identity,
-   target identity,
-   capability,
-   operation/frame.

The bridge/TCP layer performs capability validation before forwarding
remote control to the local object.

The framing and `%q` encoding are transport representations, **not
cryptographic authentication**. Strong session authentication is a
separate concern.

------------------------------------------------------------------------

# 13. Resource model

DALO models resources explicitly.

A blank object can have identity and FIFO/control presence without yet
owning an external resource.

Opening a file or binding another resource introduces physical runtime
state such as an FD.

Closing the resource should not imply destroying the object's permanent
identity.

This distinction matters for migration because:

``` text
canonical semantic state    → may migrate
physical local FD           → must be recreated/rebound
```

The same principle applies to sockets and other machine-local handles.

------------------------------------------------------------------------

# 14. Compilation strategy

The current runtime still contains compiler substrate together with the
runtime implementation, but the repository already separates a future
`compiler/` layer.

The target compilation model is:

``` text
.dalo PROJECT
      │
      ├── Object Definition ABI
      ├── Worker Definition ABI
      ├── Feature Definition ABI
      │
      ▼
validate graph + types
      │
      ▼
resolve required features
      │
      ▼
construct namespace-specialized object code
      │
      ▼
code.* / ${ns}_variables_code
      │
      ▼
link minimum global bootstrap
      │
      ▼
async_script.bash
```

The important future change is to stop linking the entire DALO library
into every generated MACHINE.

Instead, each object should request features. Feature dependencies are
resolved transitively and only those code generators/components are
emitted.

Example direction:

``` text
INLINE PIPE
  CORE
  IDENTITY
  VARIABLES
  WORKER
  DIRECT_DATA

ASYNC PIPE
  CORE
  IDENTITY
  VARIABLES
  WORKER
  DIRECT_DATA
  FIFO_FRAME
  TASK
  JOB_POOL
  ASYNC_EXEC

PERSISTENT PIPE
  CORE
  IDENTITY
  VARIABLES
  WORKER
  DIRECT_DATA
  FIFO_FRAME
  TASK
  PERSISTENT_EXEC
```

A bridge would instead pull in its transport/capability requirements.

The exact Feature Definition ABI is the next development stage; this
section describes the architectural direction rather than claiming that
the feature resolver is already complete.

------------------------------------------------------------------------

# 15. `.dalo` PROJECT language

`.dalo` is the human-readable source representation for a modeled
system.

Example:

``` text
PROJECT BranchingExample
FIELD 100 100
MAX_WORKERS 64

OBJECT source ORIGIN 10 20
OBJECT split T 20 20
OBJECT left PIPE 30 10
OBJECT right PIPE 30 30
OBJECT sink_left ENDPOINT 40 10
OBJECT sink_right ENDPOINT 40 30

EXEC source INLINE
EXEC left ASYNC
EXEC right ASYNC

CONNECT source out split in
CONNECT split out1 left in
CONNECT split out2 right in
CONNECT left out sink_left in
CONNECT right out sink_right in
```

This represents a branching system rather than an implementation script.

``` text
                         ┌──► left ──► sink_left
source ──► T(split) ─────┤
                         └──► right ─► sink_right
```

The compiler is responsible for deciding how those logical relationships
become direct calls, child boundaries, persistent workers, or bridges.

------------------------------------------------------------------------

# 16. Worker Definition ABI --- architectural direction

Object definitions answer **what an object structurally is**. Worker
definitions should answer **what computation it performs**.

The planned Worker Definition ABI should describe at least:

-   ABI version,
-   worker name,
-   implementation language/backend,
-   entry point,
-   source/artifact,
-   compatible object types,
-   input/output port types,
-   artifact hash/version,
-   statefulness where relevant.

This allows the compiler to validate a worker independently from the
logical object instance.

``` text
Object Definition       Worker Definition
      │                         │
      └──────────┬──────────────┘
                 ▼
          PROJECT instance
                 │
                 ▼
         compiler validation
```

------------------------------------------------------------------------

# 17. Feature Definition ABI --- architectural direction

Features are intended to become the unit of runtime composition.

A feature descriptor can express dependencies:

``` text
ASYNC_EXEC
   ├── FIFO_FRAME
   ├── TASK
   └── JOB_POOL
```

or:

``` text
BRIDGE_CONTROL
   ├── BRIDGE
   ├── TCP
   ├── FIFO_FRAME
   └── TCP_CAPABILITY
```

The resolver should compute a deterministic transitive closure from:

-   object type base features,
-   execution mode,
-   worker requirements,
-   instance configuration,
-   bridge/control requirements,
-   migration requirements.

This is the key to reducing generated MACHINE size without sacrificing
namespace specialization.

------------------------------------------------------------------------

# 18. Why DALO is unusual in Bash

DALO deliberately exploits properties of Bash that are often treated
only as limitations.

### Bash has process-isolated shell state

DALO turns that into an explicit ownership model and FIFO mutation
protocol.

### Bash has dynamic code evaluation

DALO turns it into validated namespace-specialized metaprogramming.

### Bash functions and variables are easy to generate

DALO uses that to build object-local executable images.

### Bash can compose OS processes naturally

DALO combines direct calls, child workers, persistent workers, FIFOs,
files, and TCP according to the actual boundary crossed.

The resulting architecture is therefore not trying to make Bash behave
like a conventional shared-memory OO runtime. It is designed around
Bash's real execution semantics.

------------------------------------------------------------------------

# 19. Invariants

The following invariants should be preserved as the implementation
evolves.

1.  **PROJECT and MACHINE are separate representations.**
2.  **Compilation is non-destructive to the PROJECT.**
3.  **UUID is stable identity; runtime namespace/obj_id may change.**
4.  **Canonical mutable state has one owning Bash context.**
5.  **A child never mutates canonical parent state by assumption.**
6.  **Child → parent canonical changes cross FIFO or an equivalent
    explicit ownership channel.**
7.  **FIFO is not the default local DATA graph transport.**
8.  **Same-context local DATA uses direct calls whenever possible.**
9.  **Cross-MACHINE DATA uses BRIDGE/TCP.**
10. **Remote CONTROL is capability-gated before entering local control
    transport.**
11. **Borrowing workers does not transfer canonical task/object
    ownership.**
12. **Physical handles such as FDs are not canonical migratable
    identity.**
13. **Generated object code is validated before becoming canonical
    code.**
14. **Namespaced stateful runtime functions should remain specialized
    unless deduplication is demonstrably free of runtime indirection
    cost.**
15. **Feature-based compilation should remove unused mechanisms, not
    genericize hot paths.**

------------------------------------------------------------------------

# 20. Current repository structure

``` text
dalo-bash/
├── README.md
├── runtime/
│   └── dalo.bash
├── compiler/
├── definitions/
│   ├── objects/
│   │   ├── origin.json
│   │   ├── pipe.json
│   │   ├── endpoint.json
│   │   ├── t.json
│   │   ├── y.json
│   │   └── bifurcator.json
│   ├── workers/
│   └── features/
├── examples/
│   └── branching.dalo
├── tests/
└── docs/
```

At the current stage, `runtime/dalo.bash` still contains historical
compiler/runtime layers accumulated during development. The architecture
is moving toward explicit compiler, runtime, object-definition,
worker-definition, and feature-definition boundaries.

------------------------------------------------------------------------

# 21. Architectural roadmap

The next major architectural steps are:

``` text
Object Definition ABI v1
          │
          ├── Worker Definition ABI v1
          │
          └── Feature Definition ABI v1
                     │
                     ▼
              dependency resolver
                     │
                     ▼
              .dalo validator
                     │
                     ▼
        feature-selective constructor
                     │
                     ▼
      canonical per-object code image
              /              \
             /                \
        migration           compiler
                                │
                                ▼
                       standalone MACHINE
```

The resulting compiler should be able to prove that an INLINE-only
object does not accidentally carry ASYNC, persistent-worker, TCP,
bridge, or migration-runtime machinery unless one of its selected
features requires it.

------------------------------------------------------------------------

# 22. Summary

DALO's architecture can be reduced to one idea:

> **Model the system logically, then compile each real execution
> boundary explicitly.**

Objects and ports describe the system. Workers provide computation.
Metaprogramming specializes Bash code for each object. Direct calls
preserve the fast local path. FIFO solves the otherwise impossible
child→parent canonical-state relationship. Bridges make MACHINE
boundaries explicit. Stable identity and canonical code/state images
enable migration. Resource leases allow computation to borrow remote
workers without confusing borrowing with ownership transfer.

The compiler's job is therefore not just to concatenate Bash source. It
is to transform a logical `.dalo` model into the smallest correct
executable realization while preserving DALO's ownership, identity,
transport, and migration invariants.
