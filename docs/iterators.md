# DALO `iterators.bashlib.sh`

## Purpose

`iterators.bashlib.sh` provides metafunctions that generate specialized
synchronous iterators, asynchronous job-pool iterators, and depth-first
recursive traversals.

Metadata:

``` bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="iterators"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="dalo helpers"
```

Recommended loading:

``` bash
DALO_LIBRARY_PATH="./runtime"
source ./runtime/library.sh
include iterators
```

The loader resolves `helpers` and `dalo` automatically.

## Why iterator generators exist

DALO deliberately uses metafunctions rather than forcing every traversal
through one generic runtime dispatcher. A `Make_*` function specializes
Bash source for known variable names, arrays, namespaces, and callback
shape.

The generated code can therefore be:

-   evaluated into the current shell;
-   namespace-specialized;
-   recorded as canonical object code when running in DALO mode;
-   reconstructed as part of a migratable/generated object image.

This is the same metaprogramming model used throughout the runtime.

## Include guard

The module uses:

``` bash
ITERATORS_INCLUDE
```

Repeated loading is a no-op.

## Installation modes

Internal helper:

``` bash
__dalo_iterator_install_body NS COMPONENT BODY
```

supports two installation contexts.

### DALO mode

When:

``` bash
DALO_INCLUDE=1
```

generated source is installed through:

``` bash
__asyncobj_eval_body
```

The source is therefore syntax-checked, evaluated, and recorded in the
namespace's canonical code image.

### Standalone mode

When:

``` bash
DALO_INCLUDE=0
```

generated source is evaluated directly.

Synchronous generators therefore accept an additional namespace argument
in DALO mode. Asynchronous generators are inherently namespaced because
they submit work to a DALO job pool.

# Synchronous generators

## `Make_iterator`

Standalone:

``` bash
Make_iterator ARRAY START_VAR END_VAR ELEMENT_VAR RETURN_VAR
```

DALO mode:

``` bash
Make_iterator NS ARRAY START_VAR END_VAR ELEMENT_VAR RETURN_VAR
```

Generates:

``` text
iterator_over_<ARRAY>
```

Generated call:

``` bash
iterator_over_ARRAY START END CALLBACK [ARGS...]
```

The iterator traverses both boundary indexes and invokes:

``` text
CALLBACK INDEX ELEMENT [ARGS...]
```

A non-zero callback status stops traversal and is propagated.

## `Make_file_iterator`

Standalone:

``` bash
Make_file_iterator NAME LINE_VAR RETURN_VAR
```

DALO mode:

``` bash
Make_file_iterator NS NAME LINE_VAR RETURN_VAR
```

Generated call:

``` bash
NAME FILE CALLBACK [ARGS...]
```

The file is read line by line. Empty lines are skipped. Callback:

``` text
CALLBACK LINE_NUMBER LINE [ARGS...]
```

## `Make_range_iterator`

Standalone:

``` bash
Make_range_iterator NAME I_VAR RETURN_VAR
```

DALO mode:

``` bash
Make_range_iterator NS NAME I_VAR RETURN_VAR
```

Generated call:

``` bash
NAME START END STEP CALLBACK [ARGS...]
```

Callback:

``` text
CALLBACK VALUE [ARGS...]
```

The current implementation uses a `VALUE <= END` termination model. It
is therefore not a general descending-range implementation; callers must
also provide a meaningful non-zero step.

## `Make_xy_iterator`

Standalone:

``` bash
Make_xy_iterator NAME X_VAR Y_VAR RETURN_VAR
```

DALO mode:

``` bash
Make_xy_iterator NS NAME X_VAR Y_VAR RETURN_VAR
```

Generated call:

``` bash
NAME X_START X_END Y_OFFSET Y_END Y_STEP CALLBACK [ARGS...]
```

For each `x`, `y` begins at:

``` text
x + Y_OFFSET
```

Callback:

``` text
CALLBACK X Y [ARGS...]
```

`Y_STEP` must be non-zero.

## `Make_glob_iterator`

Standalone:

``` bash
Make_glob_iterator NAME PATH_VAR RETURN_VAR
```

DALO mode:

``` bash
Make_glob_iterator NS NAME PATH_VAR RETURN_VAR
```

Generated call:

``` bash
NAME PATTERN CALLBACK [ARGS...]
```

The generated iterator temporarily enables `nullglob` and `dotglob`,
restores their prior state afterward, and calls:

``` text
CALLBACK PATH [ARGS...]
```

for each match.

## `Make_dir_glob_iterator`

Standalone:

``` bash
Make_dir_glob_iterator NAME PATH_VAR RETURN_VAR
```

DALO mode:

``` bash
Make_dir_glob_iterator NS NAME PATH_VAR RETURN_VAR
```

This follows the glob iterator model but submits/calls only paths
satisfying:

``` bash
[ -d PATH ]
```

A trailing slash is removed before the callback.

# Synchronous DFS recursion

## `Make_recursor`

Standalone:

``` bash
Make_recursor NAME PATH_VAR
```

DALO mode:

``` bash
Make_recursor NS NAME PATH_VAR
```

Generated call:

``` bash
NAME ROOT ENTER_CALLBACK LEAVE_CALLBACK [ARGS...]
```

Traversal order:

``` text
ENTER(root)
  child 1
  child 2
  ...
LEAVE(root)
```

An empty callback may be represented by an empty string. A non-zero
ENTER or LEAVE status terminates traversal and is propagated.

The current implementation discovers subdirectories with a `ROOT/*/`
style traversal and `-d` checks. It does not maintain an independent
visited set and does not provide general filesystem-cycle detection.

# Asynchronous generators

Asynchronous iterators submit work to the namespaced DALO job pool. They
therefore require a namespace with the corresponding job-pool API.

The important distinction is that these generators create work;
synchronization remains the responsibility of the object or
PROJECT-level wait semantics.

## `Make_async_iterator`

``` bash
Make_async_iterator NS ARRAY START_VAR END_VAR ELEMENT_VAR
```

Generates:

``` text
NS_async_iterator_over_ARRAY
```

Call:

``` bash
NS_async_iterator_over_ARRAY START END CALLBACK [CLEANUP] [ARGS...]
```

Each selected element becomes a separate job-pool submission.

## `Make_async_file_iterator`

``` bash
Make_async_file_iterator NS LINE_VAR
```

Generates:

``` text
NS_async_iterator_over_file
```

Call:

``` bash
NS_async_iterator_over_file FILE CALLBACK [CLEANUP] [ARGS...]
```

Each non-empty line is submitted as work.

## `Make_async_range_iterator`

``` bash
Make_async_range_iterator NS I_VAR
```

Call:

``` bash
NS_async_iterator_over_range START END STEP CALLBACK [CLEANUP] [ARGS...]
```

Each range value becomes a job. The same current ascending-range
limitation as the synchronous generator applies.

## `Make_async_xy_iterator`

``` bash
Make_async_xy_iterator NS X_VAR Y_VAR
```

Call:

``` bash
NS_async_iterator_over_xy X_START X_END Y_OFFSET Y_END Y_STEP CALLBACK [CLEANUP] [ARGS...]
```

Each `X Y` pair becomes a submitted job.

## `Make_async_glob_iterator`

``` bash
Make_async_glob_iterator NS PATH_VAR
```

Call:

``` bash
NS_async_iterator_over_glob PATTERN CALLBACK [CLEANUP] [ARGS...]
```

Each matching path becomes a submitted job.

## `Make_async_dir_glob_iterator`

``` bash
Make_async_dir_glob_iterator NS PATH_VAR
```

Call:

``` bash
NS_async_iterator_over_dir_glob PATTERN CALLBACK [CLEANUP] [ARGS...]
```

Only directories are submitted.

# Asynchronous DFS recursion

## `Make_async_recursor`

``` bash
Make_async_recursor NS NAME PATH_VAR
```

Generates public/implementation functions conceptually named:

``` text
NS_NAME
NS_NAME_impl
```

Public call:

``` bash
NS_NAME ROOT ENTER_CALLBACK LEAVE_CALLBACK [CLEANUP] [ARGS...]
```

Traversal itself remains depth-first and synchronous. `ENTER_CALLBACK`
executes during traversal. After descendants have been visited,
`LEAVE_CALLBACK` is submitted to the namespaced job pool.

This is important: "async recursor" does not mean that directory
discovery itself becomes an unconstrained parallel traversal.

# Example

``` bash
#!/usr/bin/env bash

DALO_LIBRARY_PATH="./runtime"
source ./runtime/library.sh
include iterators

items=(alpha beta gamma)

asyncobj_constructor DEMO
DEMO_job_pool_init 4

Make_async_iterator DEMO items begin end element
DEMO_async_iterator_over_items 0 2 worker ""
```

The exact worker lifecycle and wait semantics belong to
`dalo.bashlib.sh`; the iterator library is responsible for generating
traversal/submission functions.

# Generator inventory

``` text
SYNC
  Make_iterator
  Make_file_iterator
  Make_range_iterator
  Make_xy_iterator
  Make_glob_iterator
  Make_dir_glob_iterator
  Make_recursor

ASYNC
  Make_async_iterator
  Make_async_file_iterator
  Make_async_range_iterator
  Make_async_xy_iterator
  Make_async_glob_iterator
  Make_async_dir_glob_iterator
  Make_async_recursor
```

There are currently fourteen generator families.

# Relationship to PROJECT quiescence

Object-local job-pool waits and PROJECT-wide quiescence are different
contracts. An iterator can submit downstream work that causes further
graph activity after the originating object becomes locally idle. A
compiled PROJECT therefore uses PROJECT-level quiescence when it needs
the stronger guarantee that the complete local graph has settled.

Iterator code must not emulate this with arbitrary sleeps or by manually
waiting on a presumed graph order.
