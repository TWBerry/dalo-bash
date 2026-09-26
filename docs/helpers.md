# DALO `helpers.bashlib.sh`

## Purpose

`helpers.bashlib.sh` is the lowest-level shared utility library used by
DALO runtime modules and generated code. It deliberately contains small,
reusable mechanisms rather than object policy, scheduling policy, graph
semantics, or application behavior.

Library metadata:

``` bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="helpers"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES=""
```

`helpers` has no DALO library dependencies.

Recommended loading:

``` bash
DALO_LIBRARY_PATH="./runtime"
source ./runtime/library.sh
include helpers
```

Most applications should not need to include `helpers` directly. The
dependency-aware loader loads it automatically when a higher-level
library requires it.

## Include guard

The library uses:

``` bash
DALO_HELPERS_INCLUDE
```

Repeated sourcing therefore does not redefine the module.

## API stability

Functions whose names begin with `__` are internal DALO APIs. They are
documented because they are architecturally important, but application
code should not treat them as stable public interfaces unless a future
ABI explicitly promotes them.

Current helper family:

``` text
__asyncobj_ensure_variable_storage
__asyncobj_record_code
__asyncobj_eval_body
__asyncobj_random_hex
__asyncobj_decode_q
__dalo_sha256_file
```

## Canonical generated-code storage

DALO uses Bash as both a runtime language and a code-generation
language. Generated object components must therefore be installable into
the live shell and representable as canonical object code for
reconstruction, migration, and standalone MACHINE linking.

### `__asyncobj_ensure_variable_storage`

``` bash
__asyncobj_ensure_variable_storage NS
```

Ensures that the namespace has the storage required by generated
variables and generated code.

For namespace `FOO`, the helper prepares structures conceptually
equivalent to:

``` text
FOO_VARIABLE_TYPE
FOO_VARIABLE_VALUE
FOO_CODE_ORDER
FOO_variables_code
```

The first structures hold canonical namespaced state. `FOO_CODE_ORDER`
preserves deterministic component ordering. `FOO_variables_code` is the
aggregate Bash source image reconstructed from recorded components.

### `__asyncobj_record_code`

``` bash
__asyncobj_record_code NS COMPONENT CODE
```

Records generated Bash source as a named component of an object's
canonical code image.

The component is stored under a logical key:

``` text
code.<COMPONENT>
```

with type:

``` text
bash
```

After the update, the aggregate `${NS}_variables_code` is rebuilt in
`${NS}_CODE_ORDER`.

Important properties:

-   component order is deterministic;
-   replacing an existing component updates its value without
    duplicating its order entry;
-   the stored source is a reconstruction artifact, not merely a
    debugging dump;
-   the same representation supports runtime construction and
    migration-oriented reconstruction.

### `__asyncobj_eval_body`

``` bash
__asyncobj_eval_body NS COMPONENT BODY
```

Installs generated Bash code into the current shell and records the same
source in canonical code storage.

Conceptual sequence:

``` text
BODY
  │
  ▼
temporary source
  │
  ▼
bash -n
  │
  ▼
eval into live shell
  │
  ▼
__asyncobj_record_code
```

If syntax validation fails, the generated body is not evaluated.

This is the preferred installation path for DALO metafunctions because
it keeps live runtime behavior and the canonical reconstruction image
synchronized.

## Random identity helper

### `__asyncobj_random_hex`

``` bash
__asyncobj_random_hex [BYTES]
```

Writes a hexadecimal random value to stdout. The default size is eight
bytes.

When available, `/dev/urandom` is used. A Bash `$RANDOM`-based fallback
exists for constrained environments.

This helper is suitable for runtime identifiers and nonce-like local
values. It is not documented as a cryptographic protocol primitive.

## Bash `%q` decoding

### `__asyncobj_decode_q`

``` bash
__asyncobj_decode_q ENCODED OUTVAR
```

Decodes a Bash-escaped value and stores the result in the variable named
by `OUTVAR`.

Example:

``` bash
encoded='hello\ world'
__asyncobj_decode_q "$encoded" result
printf '%s\n' "$result"
```

Result:

``` text
hello world
```

The helper uses Bash evaluation semantics. It exists for DALO-controlled
framing and canonical encodings; it must not be treated as a general
parser for arbitrary untrusted text.

## File hashing

### `__dalo_sha256_file`

``` bash
__dalo_sha256_file FILE
```

Writes the SHA-256 digest of `FILE` to stdout.

Backend preference:

``` text
sha256sum
    ↓ fallback
shasum -a 256
```

If neither backend exists, the helper returns status `127`.

Hashes are useful for worker artifacts, generated artifacts, identity
checks, cache validation, and migration integrity checks. A digest alone
is not authentication.

## Dependency position

The current core dependency direction is:

``` text
helpers
   ↓
 dalo
   ↓
iterators
```

`helpers` must remain a mechanism layer. Object scheduling, topology,
worker semantics, orchestration policy, and distributed resource policy
belong above it.
