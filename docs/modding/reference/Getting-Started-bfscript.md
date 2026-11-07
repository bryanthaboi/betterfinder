# Getting started with typed JSON (bfscript)

## 1. Scaffold

```sh
betterfinder-mod scaffold alice.my-mod --language bfscript --template column
cd alice.my-mod
```

Templates: `column`, `sidebar`, `toolbar`, `panel`, `preview`, `command`, `theme`. `sidebar` and `theme` are data-only and need no script.

## 2. Write the script

The entry for this language is `scripts/main.bfscript.json`.

A bfscript file is a closed JSON grammar: typed records and lists, locals, conditionals, bounded `forEach` loops, and awaited catalog calls. There is no dynamic code, import or prototype access. Every expression is type-checked against the catalog, and the linter flags unreachable code, unused variables and missing cancellation checks.

```json
{"format": 1, "functions": {"columnValues": {
  "signature": "column.values@1",
  "body": [{"return": {"await": {"call": "media.imageDimensions", "args": [{"get": ["input", "items"]}]}}}]
}}}
```

Each function names the hook signature it implements (`name@version`); the manifest binds it with a `hooks` entry whose `handler` is the function name.

## 3. Validate

```sh
betterfinder-mod validate . --json
```

Output lists `file:line:col`, a stable `BF####` code and a suggested fix for every finding. The exit status is non-zero when any error is reported.

## 4. Package

```sh
betterfinder-mod package . --out alice.my-mod.bfmod
```

The archive is reproducible: sorted entries, fixed timestamps, no compression. Editor files (`betterfinder.d.ts`, `tsconfig.json`), VCS metadata and `node_modules` are left out.
