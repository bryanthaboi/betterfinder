# UI surfaces

Declare contributions in the manifest and the matching `ui.surfaces` grants. Local IDs belong to your mod; do not use reserved host namespaces. Disabling a mod disposes its registrations.

| Contribution | How it works |
| --- | --- |
| `toolbar` | Button references a declared command; `ui.setToolbarItemState` updates enabled state/title. |
| `sidebarSections` | Static known-folder or provided-location entries. Scripted lists use `locations` and `location.list`. |
| `contextMenu` | Items or background actions referencing commands. |
| `columns` | `column.values` returns one handle-keyed cell per item; batch, cache and honor revision. Set a cell's `label` when its `text` is glyphs or symbols, so VoiceOver reads a meaning such as "Large, 12 GB" instead. |
| `statusBar` | Declared item text updated with `ui.setStatusText`. |
| `panels` | Left, right or bottom; `docked` or `slideOut`; fill with `ui.setPanel`. |
| `previews` | Extension-matched `preview.render` produces a title and node tree. |
| `views` | Alternative list/grid/columns layouts using your declared columns. |
| `commands` | `command.run` executes an action and returns a message or operation ticket. |
| `keybindings` | Chords reference commands. Resolve collisions; bare-key bindings generate warnings. |
| `locations` | Read-only or capability-backed virtual listings; use provider identity, not fake file URLs. |
| `searchProviders` | `search.query` returns bounded result batches. |
| `settingsPanes` | Native controls rendered from the mod's settings schema; no script evaluation required to draw them. |
| `themes`, `iconSets`, `sounds` | Packaged data/assets; see [Retro Purple](../../examples/retro-purple/README.md). |

## ModUINode

The generated scripting type is called `UINode`; native integrations use Mod UI node representations. This is a data tree, not HTML or an AppKit object. Node types are `vstack`, `hstack`, `text`, `markdown`, `button`, `list`, `progress`, `divider`, `textField`. Fields include optional `id`, `text`, `label`, `command`, `placeholder`, `value`, `children`, `items`. A list item has `id`, `title` and optional `subtitle`.

```ts
await ui.setPanel("notes", {
  type: "vstack",
  children: [
    { type: "text", text: "Ready", label: "Panel status" },
    { type: "button", text: "Refresh", label: "Refresh notes", command: "refresh" }
  ]
});
```

Give meaningful accessibility labels, concise button titles and readable text in both appearances. Every `button` needs non-blank `text` or `label`, and every `textField` and `list` needs a `label` (a text field can use its `placeholder`). A panel update that breaks this is not shown: the panel keeps its last valid content and the app shows an error naming the node. A preview that breaks it is not shown either. Give `id`s to controls that stay on screen across updates, so keyboard focus and the caret stay put when you add or remove other nodes; ids must be unique within a tree. Button commands must be your declared commands. Do not embed web scripts, arbitrary native controls or filesystem paths that were not granted. There is no PTY control; the terminal example is a bounded command-output panel.

### Text fields

A `textField` is a single-line input. `text` is its initial value, `placeholder` the hint, and `id` is required if you want to read it back.

```ts
await ui.setPanel("notes", {
  type: "vstack",
  children: [
    { type: "textField", id: "note", placeholder: "Add a note", command: "add-note", label: "New note" },
    { type: "button", text: "Add", label: "Add note", command: "add-note" }
  ]
});
```

Pressing Return in the field runs its `command` with args `{ id, value, fields }`: the field's id, its text, and a map of every text field in the panel by id. A button's command receives `{ fields }` with the panel's current values, so a button can submit what was typed. See [Folder Notes](https://github.com/bryanthaboi/betterfinder-mod-folder-notes).

### Current location

`locations.current()` returns the front window's location. For a local folder it also returns `folder`, a `FileRef` scoped to your grants: with `fs.write` `destination` during a user gesture, or `fs.read`/`fs.write` `selection` otherwise. With neither grant it is a reference only and cannot be read or written. See [Drop Stack](https://github.com/bryanthaboi/betterfinder-mod-drop-stack).

Replacement declarations need `ui.override` in addition to ordinary surface access. Availability depends on the running app's adapters; a schema-valid surface does not prove the app has wired it. See [generated manifest](reference/Reference-Manifest.md) for all required fields and [hooks](hooks.md) for deadlines.
