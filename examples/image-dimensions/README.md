# image-dimensions

pixel sizes for selected images. reads headers through the host; no shell.

## grants

- `fs.read`: Read selected image headers
- `ui`: column

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/image-dimensions
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

select a 32 × 32 png and a text file. expect a dimensions cell for the image and an empty cell for the text file.

see [authoring guide](../../docs/modding/getting-started.md). nothing auto-enables. license: MIT.
