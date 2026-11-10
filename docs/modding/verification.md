# Docs verification

Working-tree verification, 2026-11-06, on HEAD `063461dbbe64f1a5046ed178a31ec6cf198acde4` (plus uncommitted docs and package changes). Not a clean archive or full-app gate.

## Checks

- `swift test --package-path Packages/ModValidation`: 78 tests, zero failures.
- All eight `examples/*` mods validate with the current CLI: `PASS`, zero errors, `dryRun=pass`. Terminal Panel keeps its intended `BF4006` warning (unrestricted `process.exec`). No example needed source changes; none used `storage.delete`/`storage.remove`.
- Dry runs execute for real: every hook runs with synthesized input and each `tests/*.bftest.json` is asserted. The four shipped fixtures (three Rename Guard, one Zip Selection) pass. A deliberately wrong expectation in a scratch copy of Rename Guard gave `FAIL`, `BF8005` and exit 1 (output shown in [bfscript](https://github.com/bryanthaboi/betterfinder/wiki/Writing-Mods-in-bfscript#author-tests)).
- The five published mods validated against their index listings with `validate <archive> --listing <listing.json> --authors <index>/authors`; each reported `manifest, archive and signature by bryanthaboi:2026-11 verified`, then `PASS`, `dryRun=pass`: weather-panel 1.0.0, drop-stack 1.1.0, folder-notes 1.1.0, size-heat 1.0.0, trash-cat 1.0.0.
- Reference pages and `betterfinder.d.ts` regenerated from `betterfinder-mod docs` and copied to `docs/modding/reference` and the wiki. New since last copy: `BF7011`–`BF7013`, `textField`, `--listing`/`--authors`, `--author-key`, `mcp`.
- Menu names, shortcuts and Settings labels were read from `MainMenu.swift`, `AppDelegate.swift`, `ModsMCP.swift` and `Packages/Settings`. The app was not launched for this pass, so the in-app steps are documented from source, not exercised.
- Link check across `docs/modding` and the wiki (local files, page names and heading anchors; remote URLs not fetched, repo-blob URLs mapped to the working tree): 162 links, 0 broken.

## Notes

- The catalog operation is `storage.delete`; TS/JS expose it as `storage.remove` because `delete` is reserved. The generated API table lists the catalog name.

## Exact CLI results

```text
$ betterfinder-mod validate examples/git-status-column
PASS examples.git-status-column 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: 518fff2a25e03152fad8bc8ef88bd31a059bf0097f15cd1b9839fc426dc184a0
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1 typescript/5.9.3+sha256:3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675
exit 0

$ betterfinder-mod validate examples/image-dimensions
PASS examples.image-dimensions 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: d2bb8986991ccd006155ba67cb3e8d09a012ab86e0f62b650bbbc7ad88f7b5b0
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1
exit 0

$ betterfinder-mod validate examples/markdown-previewer
PASS examples.markdown-previewer 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: 2820c942043a8bdf8a9d2de72d76d56bd0704cc34591ffc76e55d8e00a752c34
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1 typescript/5.9.3+sha256:3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675
exit 0

$ betterfinder-mod validate examples/recent-downloads
PASS examples.recent-downloads 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: 1a4035d586064555eca5be0b334254a7bd2f2ec85de7b01e5a53ed1348b7d19b
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1
exit 0

$ betterfinder-mod validate examples/rename-guard
PASS examples.rename-guard 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: ba80443e47c71d51279014aba1c62e9f2516beb1c461f75f4613620da10071f1
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1 typescript/5.9.3+sha256:3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675
exit 0

$ betterfinder-mod validate examples/retro-purple
PASS examples.retro-purple 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: 14c8084d87fe032472c369f4174c61fddc78423bc34b94df33306738b690a32d
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1
exit 0

$ betterfinder-mod validate examples/terminal-panel
PASS examples.terminal-panel 1.0.0
manifest.json:18:5 (/permissions/1): warning BF4006: unrestricted process.exec grants full user-account execution
    fix: Prefer a curated broker operation

checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 1 warning
tree sha256: bf0dad31e9675418e2f77bb03494a25e801c89bba76751b309b14a8251323fb8
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1 typescript/5.9.3+sha256:3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675
exit 0

$ betterfinder-mod validate examples/zip-selection
PASS examples.zip-selection 1.0.0
checks: schema=pass manifest=pass grants=pass paths=pass types=pass lint=pass compile=pass dryRun=pass
0 errors, 0 warnings
tree sha256: 235946ae232675feadc0a54c6e1ebe25ed218ba54ef2b91deef1011e53c9b583
validator 1.0.0, api 1.0.0, modkit/1.0.0 bfscript/1
exit 0
```
