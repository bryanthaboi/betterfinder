# rename-guard

blocks a rename if the new name ends in a space. leaves other names alone.

## grants

- `operations.intercept`: Deny destination names ending with a space

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/rename-guard
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

rename a scratch file to `report `; expect denial. rename to `report` or `two words`; expect allow. also check a batch where only one destination ends in a space.

see [authoring guide](../../docs/modding/getting-started.md). nothing auto-enables. license: MIT.
