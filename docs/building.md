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

Debug builds don't register the size indexer helper, so folder sizes come from the in-process fallback walker. To test the real LaunchAgent, install the app to `/Applications` or set `BF_REGISTER_INDEXER=1`.

## Release build

`scripts/release.sh <version> <build>` does the whole release in one pass:

1. Builds the app in Release configuration.
2. Signs it with the Developer ID identity, using Hardened Runtime.
3. Notarizes the app, then staples the ticket.
4. Produces a zip and a DMG in `dist/`.

Set `NOTARIZE=0` to skip notarization.

The release script reads signing material from `$POKEMON_CI_DIR` (default `~/.config/pokemon-ci`):
- `signing.p12`
- `signing.pass`
- `notary.env`

## CI

Pull requests run on GitHub-hosted `macos-15` with read-only repository access and no signing material. Releases run on the self-hosted macOS runner.

| Workflow | When it runs | What it does |
|---|---|---|
| `ci.yml` | Pull requests | Runs every package's tests, then builds the Debug app |
| `release.yml` | Every push to main, `v*` tags, or a manual run | Runs every package's tests, imports a temporary signing keychain, runs `scripts/release.sh` (sign, notarize, staple), and publishes a GitHub release `v0.1.<run>` |
