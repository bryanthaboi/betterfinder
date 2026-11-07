# betterfinder mods

API 1.0.0, manifest version 1, script format 1.

A mod is a folder (or a `.bfmod` archive) with a root `manifest.json`, declarative contributions and, unless it is data-only, one script. Three script languages share the same runtime, grants and validator:

- [typed JSON (`bfscript`)](Getting-Started-bfscript) — the default for generated mods
- [TypeScript](Getting-Started-TypeScript)
- [JavaScript](Getting-Started-JavaScript)

## Reference

- [API catalog](Reference-API) — namespaces, hooks, types, limits, permissions
- [Manifest fields](Reference-Manifest)
- [Diagnostic codes](Reference-Diagnostics)
- [CLI](Reference-CLI)
- `betterfinder.d.ts` — editor declarations for the virtual `betterfinder` module

## Workflow

```sh
betterfinder-mod scaffold alice.my-mod --language bfscript --template column
betterfinder-mod validate alice.my-mod
betterfinder-mod package alice.my-mod --out alice.my-mod.bfmod
```

`validate` is the single preflight used by the CLI, Settings, MCP and index CI. Any error, skipped required check, crash or timeout refuses enablement; warnings stay visible.
