# DALO OBJECT LIBRARIES — first integration patch

Add `LIBRARIES fixed` (space-separated names) under an OBJECT in `.dalo`.
The compiler validates names and resolves each requested library and its
transitive `DALO_LIBRARY_REQUIRES` closure. The existing MACHINE backend
embeds the libraries and invokes their INIT/FINI hooks.

This is the **first, compatibility-first stage**: it still embeds full
libraries and initializes them globally in the generated MACHINE, **before**
object creation. It does not yet implement per-object isolated INIT/FINI,
function-level tree shaking, or runtime discovery of dynamic function calls.
The worker never calls `include`.

Installation: extract this archive in the DALO repository root. It replaces
three compiler files. Back up or commit local changes before installing.

Run: `bash tests/test-object-libraries.bash` and `bash tests/test-fixed.bash`.
