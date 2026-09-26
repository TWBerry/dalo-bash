# DALO `helpers.bashlib.sh`

## Účel

`helpers.bashlib.sh` obsahuje nízkoúrovňové utility sdílené DALO moduly.

Metadata:

```bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="helpers"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES=""
```

`helpers` nemá žádné DALO library dependencies.

Doporučené načtení:

```bash
source ./library.sh
include helpers
```

Ve většině aplikací není nutné `helpers` includovat přímo, protože jej načte dependency resolver knihovny, která ho potřebuje.

## Include guard

Knihovna používá:

```bash
DALO_HELPERS_INCLUDE
```

Opakovaný `source` tedy neprovede znovu definici modulu.

## Status API

Funkce s prefixem `__` jsou interní DALO API. Aplikační kód by na nich neměl stavět jako na stabilním veřejném rozhraní.

Aktuální helpery:

```text
__asyncobj_ensure_variable_storage
__asyncobj_record_code
__asyncobj_eval_body
__asyncobj_random_hex
__asyncobj_decode_q
__dalo_sha256_file
```

## `__asyncobj_ensure_variable_storage`

```bash
__asyncobj_ensure_variable_storage NS
```

Připraví namespaced storage potřebný pro canonical/generated code.

Pro namespace `FOO` zajistí existenci:

```text
FOO_VARIABLE_TYPE
FOO_VARIABLE_VALUE
FOO_CODE_ORDER
FOO_variables_code
```

První tři struktury jsou vytvářeny podle potřeby jako globální arrays; `FOO_variables_code` obsahuje agregovaný generovaný Bash kód.

## `__asyncobj_record_code`

```bash
__asyncobj_record_code NS COMPONENT CODE
```

Zapíše generovaný Bash kód jako komponentu namespace.

Klíč má tvar:

```text
code.<COMPONENT>
```

Typ je uložen jako:

```text
bash
```

Po zápisu se z pořadí `NS_CODE_ORDER` znovu sestaví:

```text
NS_variables_code
```

Tím DALO zachovává canonical code image v determinovaném pořadí komponent.

Pokud komponenta již existuje, její klíč se nepřidává podruhé do `CODE_ORDER`; její hodnota se aktualizuje.

## `__asyncobj_eval_body`

```bash
__asyncobj_eval_body NS COMPONENT BODY
```

Instaluje dynamicky generovaný Bash body do aktuálního shellu a současně jej zaznamená do canonical code storage.

Postup:

```text
BODY
 ↓
temporary file
 ↓
bash -n
 ↓
eval
 ↓
__asyncobj_record_code
```

Pokud generovaný kód neprojde `bash -n`, funkce jej nevyhodnotí a vrátí chybu.

Tento helper je důležitý například pro generátory v `iterators.bashlib.sh`.

## `__asyncobj_random_hex`

```bash
__asyncobj_random_hex [BYTES]
```

Generuje hexadecimální náhodnou hodnotu.

Výchozí:

```bash
__asyncobj_random_hex
```

používá 8 bytů.

Pokud je dostupné `/dev/urandom`, čte náhodná data z něj. Jinak používá fallback založený na Bash `$RANDOM`.

Výstup je zapsán na stdout.

## `__asyncobj_decode_q`

```bash
__asyncobj_decode_q ENCODED OUTVAR
```

Dekóduje Bash-escaped hodnotu a uloží výsledek do proměnné pojmenované `OUTVAR`.

Příklad použití interního API:

```bash
encoded='hello\ world'
__asyncobj_decode_q "$encoded" result
printf '%s\n' "$result"
```

Výsledkem je:

```text
hello world
```

Helper používá Bash `eval`, proto je určen pro DALO-interní hodnoty/framing, nikoli jako obecný parser nedůvěryhodného vstupu.

## `__dalo_sha256_file`

```bash
__dalo_sha256_file FILE
```

Vrátí SHA-256 souboru na stdout.

Preferuje:

```text
sha256sum
```

a pokud není dostupný, použije:

```text
shasum -a 256
```

Pokud není dostupný ani jeden backend, vrací status `127`.

## Vztah k ostatním knihovnám

Aktuální dependency vztah:

```text
helpers
   ↓
 dalo
   ↓
iterators
```

`helpers` je spodní utility vrstva. Nemá obsahovat vysokou DALO objektovou logiku ani aplikační funkce; jeho účelem jsou malé sdílené mechanismy používané více moduly.
