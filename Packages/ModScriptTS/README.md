# ModScriptTS

Offline TypeScript 5.9.3 checking and bundling for macOS 14+, using JavaScriptCore. No ModKit dependency, Node runtime, filesystem compiler host, network access or package resolution outside the supplied source dictionary.

Create a `Catalog` from trusted host metadata and retain one `TSToolchain(catalog:)`. Each toolchain owns a lazy compiler context on a dedicated thread. Calls are synchronous and serialized; call from a background task when integrating with UI. `firstLoadTime` measures compiler evaluation only; `lastCheckTime` measures checking plus bundling when requested, in seconds. `toolchainVersion` lazily loads the compiler and returns its version and SHA-256.

`DeclarationGenerator.generate` produces the virtual `betterfinder` module. Catalog type strings are trusted TypeScript declarations, not mod input. `ModContext` supplies mod identity and generation; namespace functions and hook signatures come from the catalog. The test catalog provides `math.double(number): number` and `CalculateHandler`.

Pass package-relative source paths and contents to `check(files:entry:language:handlers:)` or `transpile(files:entry:language:handlers:)`. Supply only script files, not assets or declarations. `handlers` maps catalog hook names to entry export names; each declared handler must exist and satisfy the catalog signature. An empty map means the manifest declares no hooks. Diagnostics use stable numeric TS codes, policy codes 90001–90004, package-relative paths, and one-based line/column positions. Any error blocks output. Invalid compiler execution throws instead of returning a passing result.

JS is checked whether or not it contains `@ts-check`. Type-check suppression directives are rejected. All supplied scripts are checked and isolated as modules. Relative imports may move up directories only while remaining inside the package. Bare imports resolve only to supplied package files or directories with an index file. TypeScript-style `.js` imports can resolve to `.ts` sources. No DOM or Node declarations are included. Top-level await is disallowed. Prototype/reflection property access and `globalThis` access are deliberately restricted, including reads.

A successful transpile returns `moduleSource`, one ES2020 module backed by private CommonJS factories, and `executionSource`, an equivalent expression returning the entry export object for JSC hosts without an ES module loader. Both expect a lexical `__bf` binding supplying the catalog namespaces. Relative modules and package-bundled bare modules use only the private loader. Entry exports are snapshotted into ES module exports; use exported handler functions rather than mutable exported state. Package imports retain TypeScript's CommonJS semantics rather than full native ESM cycle/temporal-dead-zone semantics.

The AST policy is preflight, not a JavaScript security boundary. The runtime owner must supply an immutable data-only bridge, restrict runtime globals and dynamic evaluation, enforce broker authorization, and apply process isolation and watchdogs. This package does not execute mods during checking or transpilation. Tests execute generated code only with a fake bridge in a fresh JSC context.

The vendored compiler, consolidated ES2020 declaration closure, license and hashes are in `Sources/ModScriptTS/Resources/VENDOR.md`. The original declaration dependencies are consolidated to avoid shipping unrelated standard libraries. The only vendored third-party artifact is the approved TypeScript distribution.

Run `swift build --package-path Packages/ModScriptTS` and `swift test --package-path Packages/ModScriptTS`. The timing test prints `TS_BENCH` with the exact compiler receipt and measured times.
