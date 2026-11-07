# terminal-panel

slide-out command runner. set ur command in settings, then hit run. full account execution: only load code u trust. output arrives when the command exits; this is not an interactive pty. the command hook has a 10s budget.

## grants

- `ui`: panel
- `process.exec`: Run your configured shell command with your full account authority

## check it

from the repo root:

```sh
swift run --package-path Packages/ModValidation betterfinder-mod validate examples/terminal-panel
```

validate runs a dry run of every hook and any `tests/*.bftest.json`, then prints pass or fail. for the visible check, load it in a scratch window (Mods → Load Unpacked Mod…) after native approval.

set command to `printf hello`, click run, expect hello + exit 0. try `exit 3`, expect exit 3. no shell command runs on activation.

see [authoring guide](../../docs/modding/getting-started.md). nothing auto-enables. license: MIT.
