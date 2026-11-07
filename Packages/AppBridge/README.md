# AppBridge

Connects ModHost to the running app. Depends on Browser, ModHost, ModIndex, Settings, FileOps, Theming, Integration, FSCore and ModKit. Only the app target imports it.

| Type | Role |
|---|---|
| `AppModRuntime` | Builds `ModHostController` with real dependencies (XPC host, `ScopedAccessAuthorizer`, Keychain secrets/credentials, `FileOperationQueueAdapter`, `FileOperationHookRegistry.shared`, name search), attaches the sink, `ModGlobalKeybindingSink` and `ModSystemAssetRegistrar`, and runs install, developer, safe mode and log flows. `BF_MODS_ROOT=<dir>` moves all mod state to `<dir>`. |
| `BrowserModSink` | `ModUIRegistrySink` for `BrowserRegistries`. Each mod is a registry owner and its contributions are `modId/localId`. Registrations are batched per owner and flushed with `replaceAll(_:owner:)` on the next main-loop turn, so a hot reload swaps a mod's items atomically. Teardown uses `removeAll(owner:)`. Validation errors are thrown at registration time. `replaces: "builtin.x-y"` hides the matching built-in (`betterfinder/x-y`, `xY` or `x.y`) until the mod's item is removed, and the hide is undone on the next launch after a crash. |
| Adapters | ModHost column, preview, location, search and command providers mapped to Browser `ColumnProvider`, `PreviewProvider`, `LocationProvider`, `SearchProvider` and `CommandSpec` handlers. `ModUIConversion` converts a ModHost `ModUINode` into a Browser `ModUINode`. Location provider ids are `modId.localId`. |
| `ModIndexBridge` | Wraps `ModIndexClient` as ModHost's `ModIndexProviding` and `ModPackageFetching`. Downloads go through `ModArtifactDownloader`, pinned by size and SHA-256 from `verifiedListing(id:)`. If the index can't be reached (offline, private repo, 404), you get an empty offline snapshot instead of an error. A GitHub token is read from the Keychain generic password with service `betterfinder.github-token`, if one exists. |
| `AppModServices` | Destination picker, a sheet to approve full-access execution, a Keychain-backed credential prompt and a cached environment snapshot. |
| `ModEventForwarder` | A hidden status-bar segment whose per-pane driver sees every location and selection change, plus key-window and theme/appearance observers. They feed `notifyLocationChanged`, `notifySelectionChanged` (debounced 120 ms) and `notifyThemeChanged`. |
| `ModFolderWatcher` | FSEvents watcher used by Load Unpacked Mod… to hot reload on save. A failed reload keeps the previous version and shows a toast. |
| `ModSelfTest` | End-to-end check that runs inside the app. |

## Self-test

Debug builds only. The test installs every example through `AppModRuntime.install` with the real XPC host and check service, then checks `BrowserRegistries.shared`:

- the column value for a generated PNG
- the Markdown preview
- the sidebar sections and the built-in key binding
- that the location lists and a window navigates to it
- that the Zip toolbar command writes `Archive.zip`
- a dev hot reload, and that a bad reload is rejected
- that disabling a mod leaves no contributions behind

It exits 0 when every check passes.

```sh
defaults write com.bryanthaboi.betterfinder hasCompletedOnboarding -bool true
build/DerivedData/Build/Products/Debug/betterfinder.app/Contents/MacOS/betterfinder \
  --bf-selftest-mods Packages/ModKit/Sources/ModKit/Resources/Examples \
  --bf-selftest-out /tmp/selftest.json
defaults delete com.bryanthaboi.betterfinder hasCompletedOnboarding
```

Add `--bf-selftest-releases <dir with .bfmod files> --bf-selftest-index <index checkout>` to also install every listing's release through the signature-verified path (`AppModRuntime.installRelease`), check that a forged signature and a mismatched archive are refused, and, for folder-notes ≥ 1.1.0, drive the panel text field. In Debug builds `BF_MOD_HOST=subprocess` runs the live and check hosts through the embedded `betterfinder-mod __modhost` instead of the sandboxed XPC services (no `host.sandboxed` check then).

By default it uses a temporary root, a temporary defaults suite and in-memory secrets, and removes them afterwards. `--bf-selftest-keep` skips disabling and uninstalling. Combined with `BF_MODS_ROOT=<dir>`, it leaves the examples installed and enabled in `<dir>` for later launches.

## Tests

`swift test --package-path Packages/AppBridge` uses the in-process transport and private `BrowserRegistries` instances.
