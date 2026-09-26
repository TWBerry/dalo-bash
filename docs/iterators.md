# DALO `iterators.bashlib.sh`

## Účel

`iterators.bashlib.sh` obsahuje generátory synchronních a asynchronních iteratorů a DFS recursorů.

Metadata:

```bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="iterators"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="dalo helpers"
```

Doporučené načtení:

```bash
source ./library.sh
include iterators
```

Loader automaticky zajistí dependency pořadí.

## Include guard

Modul používá:

```bash
ITERATORS_INCLUDE
```

Opakované načtení knihovny je no-op.

## Režimy instalace generovaného kódu

Interní helper:

```bash
__dalo_iterator_install_body NS COMPONENT BODY
```

rozlišuje dva režimy.

### DALO režim

Pokud:

```bash
DALO_INCLUDE=1
```

generovaný body se instaluje přes:

```bash
__asyncobj_eval_body
```

Tím se kód nejen vyhodnotí, ale také uloží do namespaced/canonical code image.

### Standalone režim

Pokud:

```bash
DALO_INCLUDE=0
```

body se instaluje přímo přes:

```bash
eval
```

Synchronní `Make_*` generátory proto v DALO režimu přijímají namespace jako první argument. Async generátory jsou namespaced ze své podstaty.

---

# Synchronní iterátory

## `Make_iterator`

Standalone:

```bash
Make_iterator ARRAY START_VAR END_VAR ELEMENT_VAR RETURN_VAR
```

DALO režim:

```bash
Make_iterator NS ARRAY START_VAR END_VAR ELEMENT_VAR RETURN_VAR
```

Vytvoří:

```text
iterator_over_<ARRAY>
```

Generovaný iterator přijímá:

```bash
iterator_over_ARRAY START END CALLBACK [ARGS...]
```

Prochází indexy včetně obou hranic a volá callback:

```text
CALLBACK INDEX ELEMENT [ARGS...]
```

Nenulový návrat callbacku ukončí iteraci a propaguje návratový kód.

## `Make_file_iterator`

Standalone:

```bash
Make_file_iterator NAME LINE_VAR RETURN_VAR
```

DALO:

```bash
Make_file_iterator NS NAME LINE_VAR RETURN_VAR
```

Vytvoří funkci `NAME`.

Použití generované funkce:

```bash
NAME FILE CALLBACK [ARGS...]
```

Čte soubor po řádcích. Prázdné řádky přeskakuje.

Callback dostává:

```text
CALLBACK LINE_NUMBER LINE [ARGS...]
```

## `Make_range_iterator`

Standalone:

```bash
Make_range_iterator NAME I_VAR RETURN_VAR
```

DALO:

```bash
Make_range_iterator NS NAME I_VAR RETURN_VAR
```

Generovaná funkce:

```bash
NAME START END STEP CALLBACK [ARGS...]
```

Callback:

```text
CALLBACK VALUE [ARGS...]
```

Aktuální implementace iteruje směrem `VALUE <= END`; záporný krok tedy není obecný descending-range mechanismus. Volající musí také zajistit smysluplný nenulový `STEP`.

## `Make_xy_iterator`

Standalone:

```bash
Make_xy_iterator NAME X_VAR Y_VAR RETURN_VAR
```

DALO:

```bash
Make_xy_iterator NS NAME X_VAR Y_VAR RETURN_VAR
```

Generovaná funkce:

```bash
NAME X_START X_END Y_OFFSET Y_END Y_STEP CALLBACK [ARGS...]
```

Pro každé `x` začíná `y` na:

```text
x + Y_OFFSET
```

a iteruje do `Y_END`.

Callback:

```text
CALLBACK X Y [ARGS...]
```

Volající musí zajistit nenulový `Y_STEP`.

## `Make_glob_iterator`

Standalone:

```bash
Make_glob_iterator NAME PATH_VAR RETURN_VAR
```

DALO:

```bash
Make_glob_iterator NS NAME PATH_VAR RETURN_VAR
```

Generovaná funkce:

```bash
NAME PATTERN CALLBACK [ARGS...]
```

Dočasně zapíná:

```bash
nullglob
dotglob
```

a po dokončení obnoví původní stav.

Callback:

```text
CALLBACK PATH [ARGS...]
```

## `Make_dir_glob_iterator`

Standalone:

```bash
Make_dir_glob_iterator NAME PATH_VAR RETURN_VAR
```

DALO:

```bash
Make_dir_glob_iterator NS NAME PATH_VAR RETURN_VAR
```

Stejný model jako glob iterator, ale callback dostane pouze položky, které projdou:

```bash
[ -d PATH ]
```

Trailing `/` je před callbackem odstraněno.

---

# Synchronní DFS recursor

## `Make_recursor`

Standalone:

```bash
Make_recursor NAME PATH_VAR
```

DALO:

```bash
Make_recursor NS NAME PATH_VAR
```

Generuje depth-first traversal funkci:

```bash
NAME ROOT ENTER_CALLBACK LEAVE_CALLBACK [ARGS...]
```

Průchod:

```text
ENTER(root)
  recurse child 1
  recurse child 2
  ...
LEAVE(root)
```

Prázdný callback lze předat jako prázdný string.

Nenulový návrat `ENTER` nebo `LEAVE` zastaví traversal a propaguje návratový kód.

Aktuální implementace prochází podadresáře pomocí:

```text
ROOT/*/
```

a testu `-d`. Nemá vlastní visited-set/cycle detection.

---

# Asynchronní iterátory

Async iterátory předávají práci namespaced DALO job poolu:

```text
NS_job_pool_submit
```

Proto vyžadují odpovídající DALO namespace/job pool.

## `Make_async_iterator`

```bash
Make_async_iterator NS ARRAY START_VAR END_VAR ELEMENT_VAR
```

Vytvoří:

```text
NS_async_iterator_over_ARRAY
```

Použití:

```bash
NS_async_iterator_over_ARRAY START END CALLBACK [CLEANUP] [ARGS...]
```

Každý element je submitnut jako samostatná job-pool práce.

## `Make_async_file_iterator`

```bash
Make_async_file_iterator NS LINE_VAR
```

Vytvoří:

```text
NS_async_iterator_over_file
```

Použití:

```bash
NS_async_iterator_over_file FILE CALLBACK [CLEANUP] [ARGS...]
```

Čte neprázdné řádky a submituje jejich obsah do job poolu.

## `Make_async_range_iterator`

```bash
Make_async_range_iterator NS I_VAR
```

Vytvoří:

```text
NS_async_iterator_over_range
```

Použití:

```bash
NS_async_iterator_over_range START END STEP CALLBACK [CLEANUP] [ARGS...]
```

Každá hodnota range je submitnuta do job poolu.

Stejně jako synchronní varianta používá podmínku `VALUE <= END`; `STEP` musí být nenulový.

## `Make_async_xy_iterator`

```bash
Make_async_xy_iterator NS X_VAR Y_VAR
```

Vytvoří:

```text
NS_async_iterator_over_xy
```

Použití:

```bash
NS_async_iterator_over_xy X_START X_END Y_OFFSET Y_END Y_STEP CALLBACK [CLEANUP] [ARGS...]
```

Každá dvojice `X Y` je submitnuta do job poolu.

## `Make_async_glob_iterator`

```bash
Make_async_glob_iterator NS PATH_VAR
```

Vytvoří:

```text
NS_async_iterator_over_glob
```

Použití:

```bash
NS_async_iterator_over_glob PATTERN CALLBACK [CLEANUP] [ARGS...]
```

Každá odpovídající cesta je submitnuta jako job.

## `Make_async_dir_glob_iterator`

```bash
Make_async_dir_glob_iterator NS PATH_VAR
```

Vytvoří:

```text
NS_async_iterator_over_dir_glob
```

Použití:

```bash
NS_async_iterator_over_dir_glob PATTERN CALLBACK [CLEANUP] [ARGS...]
```

Submitují se pouze adresáře.

---

# Asynchronní DFS recursor

## `Make_async_recursor`

```bash
Make_async_recursor NS NAME PATH_VAR
```

Vytvoří:

```text
NS_NAME
NS_NAME_impl
```

Veřejná generovaná funkce:

```bash
NS_NAME ROOT ENTER_CALLBACK LEAVE_CALLBACK [CLEANUP] [ARGS...]
```

Traversal samotný je DFS.

`ENTER_CALLBACK` se provádí během traversal synchronně.

`LEAVE_CALLBACK` se po zpracování potomků submituje přes:

```text
NS_job_pool_submit
```

s volitelným cleanup callbackem.

Tento rozdíl je důležitý: async recursor neznamená, že samotná rekurzivní navigace stromem probíhá paralelně; asynchronně se submituje leave práce.

---

# Příklad s loaderem

```bash
#!/usr/bin/env bash

DALO_LIBRARY_PATH="."
source ./library.sh
include iterators

items=(alpha beta gamma)

asyncobj_constructor DEMO
DEMO_job_pool_init 4

Make_async_iterator DEMO items begin end element

DEMO_async_iterator_over_items 0 2 worker ""
```

Konkrétní worker/job-pool lifecycle závisí na API `dalo.bashlib.sh`; `iterators.bashlib.sh` pouze generuje traversal/submit funkce.

# Přehled generátorů

```text
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

Celkem 14 generátorů.
