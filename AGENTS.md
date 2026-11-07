# contributing to betterfinder

Native macOS file manager. Swift 6 toolchain, Swift v5 language mode, macOS 14+. AppKit for browsing; SwiftUI for settings and editors.

- No explanatory code comments.
- Keep public APIs in FSCore, FileOps, Theming and Integration additive or source-compatible.
- No new third-party dependencies or network package fetches. Use system frameworks and libsqlite3.
- Keep credentials and signing material outside the repository.
- Preserve unrelated working-tree changes.

## build and test

```sh
swift build --package-path Packages/<Name>
swift test --package-path Packages/<Name>
xcodegen generate
xcodebuild -project BetterFinder.xcodeproj -scheme BetterFinder -derivedDataPath build/DerivedData build
```

Run the affected package tests and build before submitting changes.
