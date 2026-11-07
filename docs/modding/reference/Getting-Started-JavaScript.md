# Getting started with JavaScript

## 1. Scaffold

```sh
betterfinder-mod scaffold alice.my-mod --language js --template column
cd alice.my-mod
```

Templates: `column`, `sidebar`, `toolbar`, `panel`, `preview`, `command`, `theme`. `sidebar` and `theme` are data-only and need no script.

## 2. Write the script

The entry for this language is `scripts/main.js`.

JavaScript is checked with the same TypeScript toolchain and strictness as TypeScript, whether or not the file has `@ts-check`. Annotate handlers with JSDoc so parameters are typed:

```js
import { media } from "betterfinder";

/** @type {import("betterfinder").ColumnValuesHandler} */
export const columnValues = async (context, input) => {
  return await media.imageDimensions(input.items);
};
```

The same import, construct and permission rules as TypeScript apply.

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
