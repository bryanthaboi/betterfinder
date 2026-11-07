# Getting started with TypeScript

## 1. Scaffold

```sh
betterfinder-mod scaffold alice.my-mod --language ts --template column
cd alice.my-mod
```

Templates: `column`, `sidebar`, `toolbar`, `panel`, `preview`, `command`, `theme`. `sidebar` and `theme` are data-only and need no script.

## 2. Write the script

The entry for this language is `scripts/main.ts`.

Scripts are checked by a pinned, vendored TypeScript compiler running offline under `strict`, `noImplicitAny` and `isolatedModules`. Every compiler diagnostic blocks enablement; there is no emit-anyway. Import only package files or the virtual `betterfinder` module, whose declarations are in `betterfinder.d.ts`.

```ts
import { media } from "betterfinder";
import type { ColumnValuesHandler } from "betterfinder";

export const columnValues: ColumnValuesHandler = async (context, input) => {
  return await media.imageDimensions(input.items);
};
```

Use catalog functions as `namespace.function(...)` so the validator can compare them with your declared permissions. `eval`, `Function`, `with`, `require`, dynamic `import()`, `globalThis`, prototype tampering, top-level `await` and `@ts-ignore` are rejected.

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
