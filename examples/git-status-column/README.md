# git-status-column

git state next to ur files. bind repository to the repo root, then show the git column. curated git.status only.

## grants

- `fs.read`: Read status for the repository you choose
- `process.exec`: Read Git status without arbitrary Git arguments
- `ui`: column

- `ui.selection`: expose row paths so git entries can be matched. the static unused-grant warning does not detect this column-input use.

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/git-status-column
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

choose a test repo with one modified file and one untracked file. expect modified/untracked on those rows and blank cells for clean files. paths must be relative to the chosen repo root; missing path metadata gives blank cells.

see [authoring guide](../../docs/modding/getting-started.md). nothing auto-enables. license: MIT.
