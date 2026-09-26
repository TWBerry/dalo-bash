# DALO `library.sh`

## Purpose

`library.sh` is the dependency-aware loader for DALO Bash libraries
(`*.bashlib.sh`). It provides deterministic dependency resolution,
metadata validation, syntax validation, cycle detection, include guards
at the loader level, and ordered loading.

A caller declares only the libraries it directly needs:

``` bash
DALO_LIBRARY_PATH="./runtime"
source ./runtime/library.sh
include iterators
```

The loader resolves the dependency closure before sourcing the new
branch. For the current core libraries:

``` text
helpers → dalo → iterators
```

`include iterators` therefore loads `helpers`, then `dalo`, then
`iterators`.

## Public API

### `include NAME`

``` bash
include iterators
```

`include` accepts one library name.

Valid names match:

``` text
[A-Za-z_][A-Za-z0-9_.-]*
```

For each directory in `DALO_LIBRARY_PATH`, the loader searches for:

``` text
<directory>/<NAME>.bashlib.sh
<directory>/<NAME>
```

Search order follows `DALO_LIBRARY_PATH` from left to right.

Repeated inclusion of an already loaded library is a no-op.

## `DALO_LIBRARY_PATH`

Default:

``` bash
DALO_LIBRARY_PATH="."
```

Multiple directories use the conventional colon separator:

``` bash
DALO_LIBRARY_PATH="./lib:$HOME/.local/lib/dalo:/opt/dalo/lib"
source ./library.sh
include my_module
```

The compiler uses the same mechanism with both compiler and runtime
directories in its search path. A central invariant is that compiler
components do not source one another directly: the compiler entry point
sources `runtime/library.sh`, then loads named modules through
`include`.

## Required library metadata

Every library loaded through `include` must contain literal metadata
assignments:

``` bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="my_module"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="dalo helpers"
```

### `DALO_LIBRARY_ABI`

Current supported value:

``` bash
DALO_LIBRARY_ABI=1
```

An unsupported ABI is rejected before the library is sourced.

### `DALO_LIBRARY_NAME`

The declared name must exactly match the requested include name.

``` bash
include compression
```

requires:

``` bash
DALO_LIBRARY_NAME="compression"
```

This prevents a path lookup from silently loading a file that claims a
different module identity.

### `DALO_LIBRARY_VERSION`

Declares the module version. The current loader records/allows the field
but does not implement version-constraint solving.

### `DALO_LIBRARY_REQUIRES`

A whitespace-separated list of direct dependencies:

``` bash
DALO_LIBRARY_REQUIRES="dalo helpers"
```

No dependencies:

``` bash
DALO_LIBRARY_REQUIRES=""
```

Dependencies are resolved transitively.

## Validation-before-source model

For a newly requested branch, DALO validates the entire unloaded
dependency closure before beginning to source that branch.

Validation includes:

1.  library-name validation;
2.  file resolution;
3.  `bash -n` syntax validation;
4.  presence and compatibility of `DALO_LIBRARY_ABI`;
5.  presence and exact match of `DALO_LIBRARY_NAME`;
6.  reading `DALO_LIBRARY_REQUIRES`;
7.  transitive dependency resolution;
8.  dependency-cycle detection.

A cycle such as:

``` text
a → b → c → a
```

is rejected before that unresolved branch is loaded.

This is intentionally stricter than a sequence of ad-hoc `source`
commands: dependency errors should be detected before a partially loaded
new dependency chain changes the shell.

## Loader state

The loader maintains global registries:

``` bash
DALO_LIBRARY_LOADED
DALO_LIBRARY_LOADED_FILE
DALO_LIBRARY_LOAD_ORDER
```

### `DALO_LIBRARY_LOADED`

Associative registry of successfully loaded module names.

### `DALO_LIBRARY_LOADED_FILE`

Maps each loaded module name to the concrete source file selected by
path resolution.

### `DALO_LIBRARY_LOAD_ORDER`

Indexed array preserving successful load order.

For example:

``` bash
DALO_LIBRARY_PATH="./runtime"
source ./runtime/library.sh
include iterators
declare -p DALO_LIBRARY_LOAD_ORDER
```

should reflect:

``` text
helpers
dalo
iterators
```

## Loader include guard

`library.sh` uses:

``` bash
DALO_LIBRARY_LOADER_INCLUDE
```

Sourcing the loader again does not reset already loaded module
registries.

## Authoring a DALO library

Example `compression.bashlib.sh`:

``` bash
#!/usr/bin/env bash

DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compression"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="dalo helpers"

if [ "${COMPRESSION_INCLUDE:-0}" -eq 0 ]; then
    COMPRESSION_INCLUDE=1
else
    return 0
fi

compression_init() {
    :
}
```

Usage:

``` bash
DALO_LIBRARY_PATH="./runtime:./lib"
source ./runtime/library.sh
include compression
```

The application does not need to include transitive dependencies itself.

## Compiler use

The DALO compiler follows the same loading discipline. The compiler
entry point establishes a path similar to:

``` bash
DALO_LIBRARY_PATH="$ROOT/compiler:$ROOT/runtime"
```

then sources only the loader directly and resolves compiler/runtime
modules with `include`.

This keeps module identity, dependency ordering, and syntax checks
consistent across normal library use and compiler construction.

## Error classes

The loader reports errors such as:

``` text
invalid library name
missing library
syntax error
missing DALO_LIBRARY_ABI metadata
unsupported library ABI
missing DALO_LIBRARY_NAME metadata
library name mismatch
dependency cycle
source failed
```

Diagnostics are written to stderr with a `library.sh:` prefix.

## Design rules

A DALO library should:

-   declare direct dependencies explicitly;
-   avoid manually sourcing its DALO dependencies;
-   use a module include guard;
-   keep metadata literal and easy for the loader to inspect;
-   avoid relying on accidental load order;
-   expose public functions intentionally and keep `__`-prefixed
    implementation details internal.

The loader is part of DALO's reproducibility boundary: a PROJECT
compiler and a runtime library should not depend on shell startup
history or incidental sourcing order.
