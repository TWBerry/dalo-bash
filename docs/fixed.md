# fixed.bashlib.sh — Q16.16 ABI v1

Load via `source runtime/library.sh` (only loader sourced directly), then `include fixed`.

All public operations use `fixed_operation OUT_VAR ARG...`, assigning into a Bash variable without subshells. Return 0 on success, 1 for range/zero-division errors, 2 for malformed arguments. All operands/results are signed Q16.16 in the interval [-2147483648,2147483647]. Multiplication and division truncate toward zero. Do not use the reserved `FIXED_*` names as output variables. Requires Bash 64-bit signed arithmetic.

Functions: `fixed_from_int`, `fixed_from_decimal`, `fixed_to_decimal`, `fixed_add`, `fixed_sub`, `fixed_mul`, `fixed_div`, `fixed_abs`, `fixed_clamp`, `fixed_tanh`, `fixed_sigmoid`.

`fixed_tanh` uses a 257-entry precomputed table with input step 1/32 on [0,8], nearest-neighbor rounding, symmetric negative inputs, and clamps beyond 8. `fixed_sigmoid(x)` is computed as `(1+tanh(x/2))/2`, using the same table. This approximation is deterministic but quantized; gradients are not implemented. `FIXED_SAT_THRESHOLD` is a diagnostic constant (~0.95), not an enforced constraint.

Example:

```bash
DALO_LIBRARY_PATH=/path/to/dalo/runtime
source /path/to/dalo/runtime/library.sh
include fixed
fixed_from_decimal a 0.5
fixed_from_decimal b -0.25
fixed_mul result "$a" "$b"
fixed_to_decimal printable "$result"
printf '%s\n' "$printable"
```

Run `bash tests/test-fixed.bash`. This library alone does not implement neuron workers, dataset loading, training, or time-step synchronization.
