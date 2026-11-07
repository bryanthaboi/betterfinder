# Writing mods in TypeScript and JavaScript

Set `runtime` to `ts/1` with a `.ts` entry, or `js/1` with a `.js` or `.mjs` entry. Export every manifest handler from that entry module. The host supplies catalog namespaces; there is no Node or DOM API.

One naming difference: the catalog operation is `storage.delete`, but because `delete` is reserved in JavaScript, TS and JS call it `storage.remove(key)`. bfscript uses the catalog name `storage.delete`.

```sh
betterfinder-mod scaffold alice.column --language ts --template column
betterfinder-mod dts --out alice.column/betterfinder.d.ts
betterfinder-mod validate alice.column --json
```

`betterfinder.d.ts` describes the virtual `betterfinder` module for editors; it does not grant permissions. Generated scaffolds include editor configuration. Compiler declarations are generated again from the installed catalog during checking; a modified local declaration file cannot expand the bridge.

```ts
import { media } from "betterfinder";
import type { ColumnValuesHandler } from "betterfinder";

export const columnValues: ColumnValuesHandler = async (context, input) => {
  return await media.imageDimensions(input.items);
};
```

The offline pinned compiler checks TypeScript with `strict`, `noImplicitAny` and `isolatedModules`. JavaScript is also checked, even without `@ts-check`. For JS handler parameter types, use JSDoc type annotations; these are type declarations, not suppression directives. Every error blocks output.

Import the virtual module or source files bundled inside the package. Relative imports must stay inside it. The compiler also resolves package-bundled bare modules and directory index files; it never fetches packages or searches the host's node_modules. Prefer explicit relative imports. TypeScript-style `.js` specifiers can resolve to `.ts` sources.

Rejected constructs include `eval`, `Function`, `with`, `require`, dynamic `import()`, top-level `await`, `globalThis`, restricted prototype/reflection access and type-check suppression directives such as `@ts-ignore`. Call broker functions directly as `namespace.function(...)`; passing namespaces around or computed catalog access prevents grant analysis and is rejected. Do not import a shell, fetch implementation or filesystem library.

The compiler emits private CommonJS factories for JSC and snapshots entry exports. Export handler functions rather than mutable exported state; module cycles do not have full native ESM semantics. Static checking is one gate; runtime handles, grants, cancellation, native approval and watchdogs still apply.

See [Markdown Previewer](../../examples/markdown-previewer/README.md), [Rename Guard](../../examples/rename-guard/README.md), [permissions](permissions.md) and [generated declarations](reference/betterfinder.d.ts).
