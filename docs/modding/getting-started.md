# Getting started

A package contains `manifest.json`, assets and optionally one entry script. Start in a scratch directory with the local CLI; no dependency download is needed.

```sh
swift run --package-path Packages/ModValidation betterfinder-mod scaffold alice.first-mod --language bfscript --template column --out /tmp/alice.first-mod
swift run --package-path Packages/ModValidation betterfinder-mod validate /tmp/alice.first-mod --json
```

Commands shown here run from the betterfinder checkout. With an installed CLI, replace the Swift prefix with `betterfinder-mod`.

Choose `bfscript`, `ts` or `js`. Templates are `column`, `sidebar`, `toolbar`, `panel`, `preview`, `command`, `theme`; sidebar and theme scaffolds are data-only regardless of language. For a scripted sidebar location, start from [Recent Downloads](../../examples/recent-downloads/README.md).

## Validate before loading

Inspect every diagnostic, including warnings and `checks`. `validate` runs the real dry run: it loads the mod in a check host, calls every hook with synthesized input and runs each `tests/*.bftest.json` (see [author tests](bfscript.md#author-tests)). The report starts with `PASS` or `FAIL` and `checks:` ends in `dryRun=pass` or `dryRun=fail`. A failed test is `BF8005`, a timeout `BF8006`, a host crash `BF8007`. Exit code is 1 on any error. `--strict` also fails when a required check did not run, which only happens in a build without the check host. Passing validation does not authorize enablement; the app still asks for native grant approval.

## Load unpacked

In the app choose **Mods → Load Unpacked Mod…** and pick your mod folder. betterfinder stages an immutable snapshot, runs preflight and asks for native grant approval before enabling it. Choose only scratch files or narrowly scoped roots. Do not copy files into the Mods store by hand.

Other entries in the **Mods** menu: **Manage Mods…** opens Settings → Mods, **Install Mod from File…** installs a `.bfmod`, **Safe Mode** disables every mod until you turn it off, **Mod Logs…** shows each mod's log, and **Start MCP Server** / **Copy MCP Config** are covered in [using the MCP server](mcp.md).

## Hot reload

Edit your files, then press ⌥⇧⌘R (**Mods → Reload Mods**). Unpacked mods also reload when their files change. A reload stages and validates a new generation; if it fails the previous working generation keeps running, and the diagnostics show in **Mod Logs…**. Disable the test mod when finished and confirm its contributions disappear.

## Install from the index

**Settings → Mods** has two tabs. **Browse** lists the mod index with search, category and sort controls and a Compatible only filter. Pick a mod to see its versions and permissions, then **Install…**: you review the permissions, the app verifies the release signature, size and hash, runs preflight, and only then offers **Enable**. **Installed** lists what you have, with Enable, Run Preflight, Update, Show Folder and Uninstall. **Mods → Install Mod from File…** does the same for a local `.bfmod`.

## Package

```sh
swift run --package-path Packages/ModValidation betterfinder-mod package /tmp/alice.first-mod --out /tmp/alice.first-mod.bfmod
```

The reproducible archive has a SHA-256 and adjacent receipt JSON. Packaging runs the same preflight, so a failing dry run blocks it; inspect the receipt before distributing. Keep the archive outside the source directory. Continue with [publishing](publishing.md), [permissions](permissions.md) and the [examples](../../examples/README.md).
