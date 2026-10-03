#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="fixed"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES=""
# Q16.16 signed fixed-point arithmetic. Bash 64-bit integer required.
# API: fixed_OPERATION OUT_VAR ARG...; return 0 on success, nonzero on error.
# Division and multiplication truncate toward zero. Never use command substitution
# in the hot path; output is assigned in the current shell.
FIXED_SCALE=65536
FIXED_MAX=2147483647
FIXED_MIN=-2147483648
FIXED_SAT_THRESHOLD=62259 # approximately 0.95 in Q16.16

_fixed_out() { [[ $1 =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && [[ $1 != FIXED_* ]]; }
_fixed_valid() { [[ $1 =~ ^-?[0-9]+$ ]] && (( ${#1} <= 11 )) && true; }
# Avoid octal interpretation and arithmetic evaluation of untrusted inputs.
_fixed_num() {
    local _f_s=$1 _f_out=$2 _f_sign=1
    [[ $_f_s =~ ^-?[0-9]+$ ]] || return 2
    [[ $_f_s == -* ]] && { _f_sign=-1; _f_s=${_f_s#-}; }
    (( ${#_f_s} <= 19 )) || return 2
    while [[ ${#_f_s} -gt 1 && $_f_s == 0* ]]; do _f_s=${_f_s#0}; done
    [[ ${#_f_s} -lt 19 || $_f_s < 9223372036854775808 ]] || return 2
    printf -v "$_f_out" '%s' "$((_f_sign * (10#$_f_s)))"
}
_fixed_range() { (( $1 >= FIXED_MIN && $1 <= FIXED_MAX )); }
fixed_from_int() {
    local _f_n _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_n || return
    (( _f_n >= -32768 && _f_n <= 32767 )) || return 1
    _f_r=$((_f_n * FIXED_SCALE)); printf -v "$1" '%d' "$_f_r"
}
fixed_from_decimal() {
    local _f_out=$1 _f_input=$2 _f_sign=1 _f_whole _f_frac _f_digits _f_r
    _fixed_out "$_f_out" || return 2
    [[ $_f_input =~ ^-?[0-9]+(\.[0-9]{1,6})?$ ]] || return 2
    [[ $_f_input == -* ]] && { _f_sign=-1; _f_input=${_f_input#-}; }
    _f_whole=${_f_input%%.*}; _f_frac=0
    [[ $_f_input == *.* ]] && _f_frac=${_f_input#*.}
    (( ${#_f_whole} <= 5 )) || return 1
    _f_whole=$((10#$_f_whole)); _f_digits=${#_f_frac}
    if [[ $_f_input == *.* ]]; then
        _f_frac=$((10#$_f_frac))
        _f_r=$((_f_whole * FIXED_SCALE + _f_frac * FIXED_SCALE / (10 ** _f_digits)))
    else
        _f_r=$((_f_whole * FIXED_SCALE))
    fi
    _f_r=$((_f_sign * _f_r)); _fixed_range "$_f_r" || return 1
    printf -v "$_f_out" '%d' "$_f_r"
}
fixed_to_decimal() {
    local _f_out=$1 _f_n _f_sign='' _f_whole _f_frac
    _fixed_out "$_f_out" || return 2
    _fixed_num "$2" _f_n || return
    _fixed_range "$_f_n" || return 1
    (( _f_n < 0 )) && { _f_sign='-'; _f_n=$((-_f_n)); }
    _f_whole=$((_f_n / FIXED_SCALE))
    _f_frac=$(((_f_n % FIXED_SCALE) * 1000000 / FIXED_SCALE))
    printf -v "$_f_out" '%s%d.%06d' "$_f_sign" "$_f_whole" "$_f_frac"
}
fixed_add() {
    local _f_a _f_b _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_a && _fixed_num "$3" _f_b || return 2
    _fixed_range "$_f_a" && _fixed_range "$_f_b" || return 1
    _f_r=$((_f_a+_f_b)); _fixed_range "$_f_r" || return 1
    printf -v "$1" '%d' "$_f_r"
}
fixed_sub() {
    local _f_a _f_b _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_a && _fixed_num "$3" _f_b || return 2
    _fixed_range "$_f_a" && _fixed_range "$_f_b" || return 1
    _f_r=$((_f_a-_f_b)); _fixed_range "$_f_r" || return 1
    printf -v "$1" '%d' "$_f_r"
}
fixed_mul() {
    local _f_a _f_b _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_a && _fixed_num "$3" _f_b || return 2
    _fixed_range "$_f_a" && _fixed_range "$_f_b" || return 1
    # Q16 operands each fit signed 32 bits: product fits signed 64 bits.
    _f_r=$((_f_a*_f_b/FIXED_SCALE)); _fixed_range "$_f_r" || return 1
    printf -v "$1" '%d' "$_f_r"
}
fixed_div() {
    local _f_a _f_b _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_a && _fixed_num "$3" _f_b || return 2
    _fixed_range "$_f_a" && _fixed_range "$_f_b" || return 1
    (( _f_b != 0 )) || return 1
    _f_r=$((_f_a*FIXED_SCALE/_f_b)); _fixed_range "$_f_r" || return 1
    printf -v "$1" '%d' "$_f_r"
}
fixed_abs() {
    local _f_n
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_n || return 2
    _fixed_range "$_f_n" || return 1
    (( _f_n < 0 )) && _f_n=$((-_f_n))
    _fixed_range "$_f_n" || return 1
    printf -v "$1" '%d' "$_f_n"
}
fixed_clamp() {
    local _f_n _f_lo _f_hi
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_n && _fixed_num "$3" _f_lo && _fixed_num "$4" _f_hi || return 2
    _fixed_range "$_f_n" && _fixed_range "$_f_lo" && _fixed_range "$_f_hi" || return 1
    (( _f_lo <= _f_hi )) || return 2
    (( _f_n < _f_lo )) && _f_n=$_f_lo
    (( _f_n > _f_hi )) && _f_n=$_f_hi
    printf -v "$1" '%d' "$_f_n"
}
# tanh LUT: 1/32 increments on [0,8], nearest-neighbor indexing.
# All lookup values are fixed constants generated at library build time.
FIXED_TANH_LUT=(
    0 2047 4091 6126 8150 10157 12146 14112 16051 17961 19838 21681 23485 25250 26973 28652
    30285 31873 33412 34904 36346 37740 39084 40379 41625 42823 43972 45075 46131 47142 48108 49031
    49912 50752 51552 52314 53038 53727 54382 55003 55593 56152 56683 57185 57660 58110 58536 58939
    59320 59680 60019 60340 60643 60929 61199 61454 61694 61920 62134 62335 62524 62703 62871 63029
    63179 63319 63451 63576 63693 63803 63907 64004 64096 64182 64263 64340 64412 64479 64543 64603
    64659 64712 64761 64808 64852 64893 64932 64968 65003 65035 65065 65093 65120 65145 65169 65191
    65212 65231 65250 65267 65283 65299 65313 65327 65339 65351 65362 65373 65383 65392 65401 65409
    65417 65424 65431 65437 65443 65449 65454 65459 65464 65468 65472 65476 65480 65483 65486 65489
    65492 65495 65497 65500 65502 65504 65506 65508 65509 65511 65512 65514 65515 65516 65518 65519
    65520 65521 65522 65523 65523 65524 65525 65526 65526 65527 65527 65528 65528 65529 65529 65530
    65530 65530 65531 65531 65531 65532 65532 65532 65532 65533 65533 65533 65533 65533 65534 65534
    65534 65534 65534 65534 65534 65534 65534 65535 65535 65535 65535 65535 65535 65535 65535 65535
    65535 65535 65535 65535 65535 65535 65535 65535 65536 65536 65536 65536 65536 65536 65536 65536
    65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536
    65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536
    65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536 65536
    65536
)
fixed_tanh() {
    local _f_n _f_abs _f_index _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_n || return 2
    _fixed_range "$_f_n" || return 1
    _f_abs=$_f_n; (( _f_abs < 0 )) && _f_abs=$((-_f_abs))
    _f_index=$(((_f_abs+1024)/2048))
    (( _f_index > 256 )) && _f_index=256
    _f_r=${FIXED_TANH_LUT[_f_index]}
    (( _f_n < 0 )) && _f_r=$((-_f_r))
    printf -v "$1" '%d' "$_f_r"
}
fixed_sigmoid() {
    local _f_n _f_half _f_t _f_r
    _fixed_out "$1" || return 2
    _fixed_num "$2" _f_n || return 2
    _fixed_range "$_f_n" || return 1
    _f_half=$((_f_n/2))
    fixed_tanh _f_t "$_f_half" || return
    _f_r=$(((FIXED_SCALE+_f_t)/2))
    printf -v "$1" '%d' "$_f_r"
}
