# markdown-previewer

markdown preview for ur selected .md file. reads up to 256 kib; native markdown, no web page.

## grants

- `fs.read`: Read the selected Markdown file
- `ui`: preview

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/markdown-previewer
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

preview a file containing `# hello`. expect the title and rendered heading. preview an empty markdown file; expect an empty body.

see [authoring guide](../../docs/modding/getting-started.md). nothing auto-enables. license: MIT.
