# Building and CI

## Local build

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project BetterFinder.xcodeproj -scheme BetterFinder -derivedDataPath build/DerivedData build
```

Each package also builds and tests on its own:

```sh
for p in FSCore FileOps Theming Integration Settings Browser Updates ModKit ModScriptTS ModValidation ModHost ModIndex MCPServer AppBridge Remote; do swift test --package-path Packages/$p; done
```

`scripts/test-packages.sh` runs them all, four packages at a time (`TEST_JOBS` changes that). Pass package names to run a subset. Set `SPM_SCRATCH_ROOT` to keep the build products outside the package folders.

Debug builds don't register the size indexer helper, so folder sizes come from the in-process fallback walker. To test the real LaunchAgent, install the app to `/Applications` or set `BF_REGISTER_INDEXER=1`.

## Release build

`scripts/release.sh <version> <build>` does the whole release in one pass:

1. Builds the app in Release configuration.
2. Signs it with the Developer ID identity, using Hardened Runtime.
3. Notarizes the app, then staples the ticket.
4. Produces a zip and a DMG in `dist/`.

Set `NOTARIZE=0` to skip notarization.

Set `DERIVED_DATA` to build in a different DerivedData folder. Compiled intermediates there are reused between runs; the app bundle is always rebuilt from them.

The release script reads signing material from `$POKEMON_CI_DIR` (default `~/.config/pokemon-ci`):
- `signing.p12`
- `signing.pass`
- `notary.env`

## CI

Pull requests run on GitHub-hosted `macos-15` with read-only repository access and no signing material. Releases run on the self-hosted macOS runner. The runner keeps SwiftPM and Xcode build products in `~/Library/Caches/betterfinder-ci` between runs, so only changed code is recompiled. `v*` tags and manual runs with `clean` checked delete that folder first and build from scratch.

| Workflow | When it runs | What it does |
|---|---|---|
| `ci.yml` | Pull requests | Runs every package's tests in parallel, then builds the Debug app |
| `release.yml` | Every push to main, `v*` tags, or a manual run | Runs every package's tests in parallel, imports a temporary signing keychain, runs `scripts/release.sh` (sign, notarize, staple), and publishes a GitHub release `v0.1.<run>` |
