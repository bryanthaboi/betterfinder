# recent-downloads

a recent section for ur downloads. bind downloads to a folder u choose.

## grants

- `fs.read`: List the Downloads folder you choose
- `ui`: sidebar, location

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/recent-downloads
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

choose a scratch downloads folder with two differently dated files. open downloads → recent. expect newest first. this bounded example shows one page, up to 128 items.

see [authoring guide](https://github.com/bryanthaboi/betterfinder/wiki/Getting-Started). nothing auto-enables. license: MIT.
