# ModHost

App-side mod runtime for betterfinder.

## Targets

| Target | Role |
|---|---|
| `ModHostProtocol` | Data-only wire messages (JSON, 1 MiB cap), framing, XPC endpoint protocol. |
| `ModHostRuntime` | JavaScriptCore engine used inside the sandboxed host: one `JSVirtualMachine`/`JSContext` per mod generation, hardened globals, frozen `__bf` bridge (all `BFLanguage.runtimeMembers` plus catalog namespaces for TS/JS), watchdog, memory stats, XPC listener delegate with code-signing peer requirement, stdio server. |
| `ModHost` | `ModHostController` (store, grants, preflight + dry run, install/enable/disable/uninstall, hot reload, rollback, safe mode), broker with grant enforcement, transports (XPC, subprocess, in-process), `ModUIRegistrySink`, Settings/Theming/FileOps/Integration adapters. |
| `bf-modhost-runner` | Stdio host for tests and signed smoke runs. |

`BetterFinderModHost/` holds the shared `main.swift` for the two embedded services: `BetterFinderModHost.xpc` (live mods) and `BetterFinderModCheck.xpc` (preflight dry runs, never the live host).

## Preflight and dry run

`check` runs `ModValidator` (the same preflight as the CLI and index CI) with ModHost's dry run plugged in. The dry run loads the mod into a warm check host, runs every hook with synthesized input and every `tests/*.bftest.json`, and reports BF8005–BF8007. The check host is reused across dry runs and stopped after 30 s idle, so the XPC check service is not respawned inside launchd's 10 s throttle; a host that dies is retried after 11 s. `ModHostDryRunner` exposes this as a `DryRunning` for the CLI and the MCP server. `installRelease` refuses archives whose author signature, size, SHA-256 or manifest don't match the listing.

## Storage

`~/Library/Application Support/betterfinder/Mods/<id>/<version>/` immutable snapshots (0444/0555), `Mods/<id>/state.json`, `Mods/<id>/.compiled/`, `Mods/health.json`; `ModData/<id>/{grants.json,storage.json,mod.log}` (0600).

## Budgets

250 ms per synchronous JS turn (watchdog kills the host process), hook deadline + 1.5 s grace app-side, 128 MiB host footprint restart when idle, 3 host failures in 120 s enter safe mode, 3 quarantines suspend a mod. All in `ModRuntimeOptions` / `ModHostConfig`.

## Tests

`swift test --package-path Packages/ModHost`. Watchdog, crash and memory tests use the real `bf-modhost-runner` subprocess. Signed sandbox smoke:

```sh
mkdir -p /tmp/s/ModHostSmoke.app/Contents/MacOS && cp Packages/ModHost/.build/debug/bf-modhost-runner /tmp/s/ModHostSmoke.app/Contents/MacOS/
# Info.plist with CFBundleIdentifier + CFBundleExecutable, then:
codesign -s - -f -o runtime --entitlements BetterFinderModHost/BetterFinderModHost.entitlements /tmp/s/ModHostSmoke.app
MODHOST_SMOKE_RUNNER=/tmp/s/ModHostSmoke.app/Contents/MacOS/bf-modhost-runner swift test --package-path Packages/ModHost --filter SmokeTests
```
