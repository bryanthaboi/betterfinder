<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.png">
  <img src="docs/assets/logo.png" width="420" alt="betterfinder">
</picture>

**finder but better.** native macos file manager. list view by default, real folder sizes, space to preview, an up button that actually works, and themes that go all the way back to system 7.

[![release](https://github.com/bryanthaboi/betterfinder/actions/workflows/release.yml/badge.svg)](https://github.com/bryanthaboi/betterfinder/releases/latest)
![macOS](https://img.shields.io/badge/macOS-14%2B%20apple%20silicon-000000?logo=apple&logoColor=white)

<img src="docs/assets/screenshot.png" width="720" alt="betterfinder showing a folder with sizes next to every subfolder">

</div>

[download the latest release](https://github.com/bryanthaboi/betterfinder/releases/latest), open the dmg, drag it to applications.

## what it does

- **list view default.** detailed columns out of the box, sort + layout stick everywhere, never writes `.DS_Store`. <kbd>⇧</kbd><kbd>⌘</kbd><kbd>;</kbd> keeps folders on top
- **folder sizes.** right in the size column, straight out of a background file index. no recounting when u open a folder, renames + moves keep their size
- **heat column.** a little colored bar per row, blue for tiny up to red for huge, same scale in every folder. click the header to sort by it
- **space hog.** view → space hog (<kbd>⌃</kbd><kbd>⌘</kbd><kbd>H</kbd>) draws whats eating ur disk as a map, windirstat style, straight off the index so it opens instantly. double click to zoom in, tiny numbers at the bottom say how far along the index is
- **clean up junk.** finds caches, logs, package manager leftovers, rebuildable project folders, old installers and piles of empty leftover folders. nothing is ticked for u, and everything goes to the trash
- **space = quick look.** real system quick look, arrow keys follow along, works in list/column/icon views
- **up button that always works.** <kbd>⌘</kbd><kbd>↑</kbd> from anywhere, incl search results + recents. selects where u came from
- **path bar u can type in.** <kbd>⌘</kbd><kbd>L</kbd>, tab completion, `~`, paste a `file://` url
- **real cut + paste.** <kbd>⌘</kbd><kbd>X</kbd> then <kbd>⌘</kbd><kbd>V</kbd> moves it. like a normal computer
- **filter as u type.** type `*.zip` and the folder narrows instantly, or right click a kind → filter by. <kbd>esc</kbd> clears it
- **search this folder.** <kbd>⌘</kbd><kbd>F</kbd> searches where u are, not "this mac". name search runs off the same index so its basically instant, even across ur whole home
- **tabs + dual pane.** <kbd>⌘</kbd><kbd>⇧</kbd><kbd>D</kbd> or double click a tab for two panes, <kbd>F5</kbd>/<kbd>F6</kbd> copy/move across, <kbd>⌥</kbd><kbd>⇥</kbd> hops between em. each pane can have its own sidebar. folders can open in tabs like a browser if u want
- **tabs u can drop on.** drag files onto a tab to move em there, drag a folder between two tabs to open it as a new one
- **visor.** a window docked to the bottom of ur screen that slides up on a hotkey, quake console style. <kbd>⌥</kbd><kbd>`</kbd> or double tap <kbd>⌥</kbd>. slides away when u switch apps, pin it to keep it, shows on every space and can sit above the dock
- **colored labels.** tagged files get the whole row tinted like old finder. list, column and icon view
- **columns that fit.** column view sizes each column to its longest name
- **right click that helps.** new ▸ and open in terminal are always there, w the terminal app of ur choice
- **copy path ur way.** <kbd>⌥</kbd><kbd>⌘</kbd><kbd>C</kbd> for the plain path, or copy path as ▸ url, windows, unc, hfs or terminal escaped
- **get info + mini info.** hold <kbd>⌥</kbd> for a small floating card. drives show capacity + whats used
- **copy queue.** pause, resume, retry, conflict dialog w apply-to-all, undo everything, optional checksum verify
- **put back that works.** own trash journal so put back doesnt randomly break. file → recently trashed… lists it all
- **eject tells u who's blocking.** names the app holding the drive + offers to quit it
- **sftp + s3.** <kbd>⌘</kbd><kbd>K</kbd> to connect. browse, copy, move between local, sftp, s3 (r2/minio too). moves verify before deleting
- **hide ur home name.** show it real, as `~`, custom, or blurred. for screenshots + streams
- **status bar ur way.** reorder or turn off any item, incl ones from mods
- **themes.** 9 built in, every one editable live. fork, tweak, export as `.bftheme`. color sidebar icons if u miss em
- **mods.** panels, columns, toolbar buttons, commands and more. see below
- **replaces finder.** one switch makes "show in finder" + folder opens go here. one button to undo it
- **updates itself.** checks for new releases and swaps itself in

## themes

every built-in is fully customizable in settings → appearance. edits fork the theme, reset puts it back.

<table>
<tr>
<td align="center"><img src="docs/assets/themes/preview-platinum.png" width="260"><br><sub><b>platinum</b> · mac os 8/9</sub></td>
<td align="center"><img src="docs/assets/themes/preview-system7.png" width="260"><br><sub><b>system 7</b> · 1-bit</sub></td>
<td align="center"><img src="docs/assets/themes/preview-aqua.png" width="260"><br><sub><b>aqua</b> · early os x</sub></td>
</tr>
<tr>
<td align="center"><img src="docs/assets/themes/preview-classic-windows.png" width="260"><br><sub><b>classic windows</b> · 95/98</sub></td>
<td align="center"><img src="docs/assets/themes/preview-luna.png" width="260"><br><sub><b>luna</b> · xp-ish</sub></td>
<td align="center"><img src="docs/assets/themes/preview-high-contrast.png" width="260"><br><sub><b>high contrast</b></sub></td>
</tr>
<tr>
<td align="center"><img src="docs/assets/themes/preview-modern.png" width="260"><br><sub><b>modern</b> · follows system</sub></td>
<td align="center"><img src="docs/assets/themes/preview-modern-light.png" width="260"><br><sub><b>modern light</b></sub></td>
<td align="center"><img src="docs/assets/themes/preview-modern-dark.png" width="260"><br><sub><b>modern dark</b></sub></td>
</tr>
</table>

retro themes are drawn in code. no apple or microsoft fonts, icons or sounds are shipped.

## replacing finder

macos doesnt let anything fully replace finder. heres what actually moves over:

| what | moves over |
|---|:---:|
| "show in finder" from other apps (vs code, chrome, etc) | yes |
| `open ~/some/folder` + apps opening folders | yes |
| dock stacks / spotlight <kbd>⌘</kbd><kbd>↩</kbd> | sometimes |
| desktop icons, open/save dialogs, airdrop | no |


## more

<details>
<summary><b>build it urself</b></summary>

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project BetterFinder.xcodeproj -scheme BetterFinder -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/betterfinder.app
```

tests per package: `swift test --package-path Packages/Browser` (etc). more in [building + ci](https://github.com/bryanthaboi/betterfinder/wiki/Building)

</details>

<details>
<summary><b>windows keys</b></summary>

opt-in in settings. enter opens, f2 renames, backspace goes up, f5 refreshes, forward delete trashes. copy to other pane moves to <kbd>⇧</kbd><kbd>F5</kbd> while its on. ur mac shortcuts still work too.

</details>

## mods

everything is moddable: panels, slide-outs, toolbar buttons, columns, previewers, sidebar sections, commands, file op hooks, themes, icon sets. mods run sandboxed and get checked before they turn on. anything that fails the check stays off.

write em in `bfscript` (typed json), typescript or js. browse + install from settings → mods, or from the [mod index](https://github.com/bryanthaboi/betterfinder-mod-index).

| mod | what |
|---|---|
| [git-panel](https://github.com/bryanthaboi/betterfinder-mod-git-panel) | branch in the status bar, side panel w status + branch switcher, right click → gitignore or hide from git |
| [weather-panel](https://github.com/bryanthaboi/betterfinder-mod-weather-panel) | temp in the status bar, slide-out forecast for ur city |
| [drop-stack](https://github.com/bryanthaboi/betterfinder-mod-drop-stack) | path finder style shelf, stash files then drop em somewhere |
| [folder-notes](https://github.com/bryanthaboi/betterfinder-mod-folder-notes) | sticky notes per folder |
| [size-heat](https://github.com/bryanthaboi/betterfinder-mod-size-heat) | size bars column on a fixed scale, folders included. built in now as the heat column, still a good example of a column mod |
| [trash-cat](https://github.com/bryanthaboi/betterfinder-mod-trash-cat) | a cat in ur status bar that eats ur trash |

turn on developer mode in settings → mods and u get a built in mcp server, so an mcp client can scaffold, test, hot load and package a mod for u. docs live in the [wiki](https://github.com/bryanthaboi/betterfinder/wiki).

<details>
<summary><b>make one</b></summary>

```sh
betterfinder-mod scaffold me.cool-thing --language ts --template panel
betterfinder-mod validate me.cool-thing
```

then mods → load unpacked mod… and it hot reloads on save. [guide →](https://github.com/bryanthaboi/betterfinder/wiki/Modding)

</details>

---

<div align="center"><sub>made by <a href="https://github.com/bryanthaboi">bryanthaboi</a></sub></div>

## license

[GPLv3 with additional terms](LICENSE). Copyright (C) 2026 BOIS CLUB GAMES, LLC.
