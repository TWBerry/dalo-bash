# DALO `library.sh`

## Účel

`library.sh` je dependency-aware loader pro DALO Bash knihovny (`*.bashlib.sh`).

Uživatel deklaruje pouze knihovnu, kterou chce použít:

```bash
source ./library.sh
include iterators
```

Loader automaticky vyhledá `iterators.bashlib.sh`, přečte její závislosti, ověří celý dosud nenačtený dependency closure a načte knihovny ve správném pořadí.

Pro aktuální moduly:

```text
helpers → dalo → iterators
```

Proto `include iterators` automaticky načte `helpers`, potom `dalo` a nakonec `iterators`.

## Veřejné API

### `include NAME`

```bash
include iterators
```

`include` přijímá právě jeden název knihovny.

Povolený název odpovídá:

```text
[A-Za-z_][A-Za-z0-9_.-]*
```

Loader hledá postupně:

```text
<directory>/<NAME>.bashlib.sh
<directory>/<NAME>
```

ve všech adresářích `DALO_LIBRARY_PATH`.

Opakované načtení stejné knihovny je no-op:

```bash
include iterators
include iterators
```

Druhé volání už znovu neprovádí dependency resolution ani `bash -n`.

## `DALO_LIBRARY_PATH`

Výchozí hodnota:

```bash
DALO_LIBRARY_PATH="."
```

Více cest se odděluje dvojtečkou:

```bash
DALO_LIBRARY_PATH="./lib:$HOME/.local/lib/dalo:/opt/dalo/lib"
source ./library.sh

include my_module
```

Cesty jsou prohledávány zleva doprava.

## Metadata knihovny

Každá knihovna načítaná přes `include` musí obsahovat literal metadata assignments:

```bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="my_module"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="dalo helpers"
```

### `DALO_LIBRARY_ABI`

Aktuálně podporovaná hodnota:

```bash
DALO_LIBRARY_ABI=1
```

Loader odmítne nepodporované ABI.

### `DALO_LIBRARY_NAME`

Musí přesně odpovídat názvu použitému v `include`.

Například:

```bash
include compression
```

vyžaduje:

```bash
DALO_LIBRARY_NAME="compression"
```

### `DALO_LIBRARY_VERSION`

Verze knihovny. Současný loader ji evidenčně umožňuje deklarovat, ale neprovádí version constraint resolution.

### `DALO_LIBRARY_REQUIRES`

Whitespace-separated seznam přímých závislostí:

```bash
DALO_LIBRARY_REQUIRES="dalo helpers"
```

Prázdný seznam:

```bash
DALO_LIBRARY_REQUIRES=""
```

Loader závislosti řeší transitivně.

## Validace před načtením

Pro jeden nový `include` se nejprve validuje celý dosud nenačtený dependency closure. Teprve potom začne `source`.

Validace zahrnuje:

1. nalezení souboru,
2. `bash -n`,
3. `DALO_LIBRARY_ABI`,
4. `DALO_LIBRARY_NAME`,
5. načtení `DALO_LIBRARY_REQUIRES`,
6. transitivní resolution,
7. detekci dependency cycle.

Příklad cyklu:

```text
a → b → c → a
```

je odmítnut před načtením této nové větve.

## Stav loaderu

Loader udržuje tři globální struktury:

```bash
DALO_LIBRARY_LOADED
DALO_LIBRARY_LOADED_FILE
DALO_LIBRARY_LOAD_ORDER
```

### `DALO_LIBRARY_LOADED`

Associative array:

```bash
declare -p DALO_LIBRARY_LOADED
```

Obsahuje jména úspěšně načtených knihoven.

### `DALO_LIBRARY_LOADED_FILE`

Mapuje jméno knihovny na skutečně načtený soubor.

### `DALO_LIBRARY_LOAD_ORDER`

Indexed array zachovávající pořadí úspěšného načtení.

Například:

```bash
source ./library.sh
include iterators
declare -p DALO_LIBRARY_LOAD_ORDER
```

odpovídá dependency pořadí:

```text
helpers
dalo
iterators
```

## Include guard loaderu

`library.sh` používá:

```bash
DALO_LIBRARY_LOADER_INCLUDE
```

Opakovaný `source library.sh` neprovede novou inicializaci loaderu a nesmaže registry již načtených knihoven.

## Vlastní knihovna

Příklad `compression.bashlib.sh`:

```bash
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

Použití:

```bash
source ./library.sh
include compression
```

Uživatel nemusí explicitně načítat `dalo` ani `helpers`.

## Chybové stavy

Loader hlásí mimo jiné:

```text
missing library
syntax error
missing DALO_LIBRARY_ABI metadata
unsupported library ABI
missing DALO_LIBRARY_NAME metadata
library name mismatch
dependency cycle
source failed
invalid library name
```

Chyby jsou zapisovány na stderr s prefixem:

```text
library.sh:
```

## Doporučený model

Aplikační skript:

```bash
#!/usr/bin/env bash

DALO_LIBRARY_PATH="./lib"
source ./library.sh

include iterators
include my_project_library

# application
```

Knihovny deklarují své vlastní závislosti. Aplikace deklaruje jen moduly, které přímo používá.
