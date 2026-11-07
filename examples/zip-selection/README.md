# zip-selection

select files, hit zip, choose where it goes. uses the queued archiver, no arbitrary shell.

## grants

- `fs.read`: Read the items you select to archive them
- `fs.write`: Write the archive into the folder you choose
- `process.exec`: Create the archive with the built-in archiver
- `ui`: toolbar

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/zip-selection
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

select two scratch files and click zip. choose a writable scratch folder; expect Archive.zip and an operation ticket. cancel the picker; expect no archive. empty selection asks u to select something.

see [authoring guide](../../docs/modding/getting-started.md). nothing auto-enables. license: MIT.
