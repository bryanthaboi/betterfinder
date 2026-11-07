# Modding documentation

- [Getting started](getting-started.md)
- [Writing mods in bfscript](bfscript.md)
- [Writing mods in TypeScript and JavaScript](typescript-and-js.md)
- [Permissions](permissions.md)
- [Hooks](hooks.md)
- [UI surfaces](ui-surfaces.md)
- [Publishing to the mod index](publishing.md)
- [Using the MCP server](mcp.md)
- [Troubleshooting](troubleshooting.md)

- [Examples](../../examples/README.md)
- [Verification results](verification.md)
- [Generated reference](reference/Home.md)

## Real world examples

Five published mods, each a TypeScript package with a signed release in the [mod index](https://github.com/bryanthaboi/betterfinder-mod-index). Install them from Settings → Mods → Browse.

| Mod | What it does |
| --- | --- |
| [weather-panel](https://github.com/bryanthaboi/betterfinder-mod-weather-panel) | Slide-out panel with current weather and a 3 day forecast. Only talks to Open-Meteo. |
| [drop-stack](https://github.com/bryanthaboi/betterfinder-mod-drop-stack) | Stash files from anywhere, then copy or move the pile into the folder you are in. |
| [folder-notes](https://github.com/bryanthaboi/betterfinder-mod-folder-notes) | Sticky notes per folder, using a panel `textField` and mod storage. |
| [size-heat](https://github.com/bryanthaboi/betterfinder-mod-size-heat) | Heat column with a small text bar showing each item's size against its siblings. |
| [trash-cat](https://github.com/bryanthaboi/betterfinder-mod-trash-cat) | Status bar cat that eats what you trash and keeps score. |

Generated pages and editor declarations are copied from `betterfinder-mod docs --out <temporary-directory>`. Regenerate them with the same reviewed CLI after catalog changes; only relative Markdown link suffixes are adapted for repository browsing.
