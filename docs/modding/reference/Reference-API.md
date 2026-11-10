# betterfinder mod API 1.0.0

Generated from the ModKit catalog (digest `f4307c2862dc902e53347b79cc166a986c3f91d11a0e07fc24f33c2d55fb5856`). Manifest version 1, script format 1, toolchain `modkit/1.0.0 bfscript/1`.

## Limits

| Limit | Value |
|---|---|
| Manifest bytes | 262144 |
| Script bytes | 1048576 |
| Callback watchdog (ms) | 250 |
| Control message bytes | 1048576 |
| Batch items | 128 |
| Host RSS restart (MiB) | 128 |
| Max permissions | 64 |
| Max contributions per kind | 64 |
| Max hooks | 128 |
| Max settings | 128 |
| Max dependencies | 16 |
| Max conflicts | 16 |
| Max package bytes | 67108864 |
| Max package files | 2048 |
| bfscript max functions | 64 |
| bfscript max statements | 2048 |
| bfscript max statement nesting | 16 |
| bfscript max expression depth | 32 |
| bfscript max loop bound | 10000 |
| bfscript max total loop iterations | 1000000 |
| bfscript max loop nesting | 3 |
| bfscript max call depth | 8 |

## Permissions

| Kind | Required fields | Optional fields | Meaning |
|---|---|---|---|
| `fs.read` | `scope`, `reason` | `recursive`, `rootId` | Read files via gesture-scoped selection handles or a user-picked root. |
| `fs.write` | `scope`, `reason` | `recursive`, `rootId` | Write files into a user-chosen destination, root or selection. |
| `net` | `endpoints`, `reason` | `allowPrivate`, `maxBytes` | HTTP(S) to listed scheme/host/port/method endpoints; private networks denied unless allowed. |
| `process.exec` | `mode`, `reason` | `operations` | Curated broker operations, or unrestricted full user-account execution (high trust). |
| `ui` | `surfaces` |  | Register UI contributions on the listed surfaces. |
| `ui.override` | `surfaces`, `reason` |  | Reorder, hide or replace host built-ins on the listed surfaces. |
| `ui.selection` | `level`, `reason` |  | Receive passive selection metadata at the declared level. |
| `credentials` | `destinations`, `reason` |  | Use Keychain credentials as opaque handles bound to listed destinations. |
| `storage` |  | `quotaBytes` | Mod-private key/value storage. |
| `operations.observe` | `operations`, `reason` |  | Observe committed file operation outcomes. |
| `operations.intercept` | `operations`, `reason` |  | Veto file operations before they start (allow or deny). |

## Contributions

| Key | UI grant surface | Handler hook | Meaning |
|---|---|---|---|
| `toolbar` | `toolbar` | none | Toolbar buttons that run a command. |
| `sidebarSections` | `sidebar` | none | Sidebar sections of known folders or provided locations. |
| `contextMenu` | `contextMenu` | none | Context menu items for items or the folder background. |
| `columns` | `column` | `column.values` | List columns computed by a column.values handler. |
| `statusBar` | `statusBar` | none | Status bar items whose text is set via ui.setStatusText. |
| `panels` | `panel` | none | Docked or slide-out panels filled via ui.setPanel. |
| `previews` | `preview` | `preview.render` | Previewers for file extensions rendered by preview.render. |
| `views` | `view` | none | Alternative browse layouts using this mod's columns. |
| `locations` | `location` | `location.list` | Virtual locations listed by location.list. |
| `commands` | none | `command.run` | Commands run by command.run. |
| `keybindings` | none | none | Key chords bound to commands. |
| `settingsPanes` | none | none | Settings panes rendered from this mod's settings schema. |
| `themes` | none | none | Theme JSON files from the package. |
| `iconSets` | none | none | Icon set directories from the package. |
| `sounds` | none | none | Sound set directories from the package. |
| `searchProviders` | `search` | `search.query` | Search providers backed by search.query. |

## Hooks

All hooks are async `(context: HookContext, input) → result`.

| Signature | Input | Result | Requires | Deadline | Cancellable | Failure | Multiple |
|---|---|---|---|---|---|---|---|
| `activate@1` | `ActivateInput` | `void` | none | 2000 ms | no | reject | no |
| `deactivate@1` | `DeactivateInput` | `void` | none | 1000 ms | no | ignore | no |
| `selection.changed@1` | `SelectionChangedInput` | `void` | `ui.selection` | 250 ms | yes | ignore | no |
| `location.changed@1` | `LocationChangedInput` | `void` | none | 250 ms | yes | ignore | no |
| `theme.changed@1` | `ThemeChangedInput` | `void` | none | 250 ms | yes | ignore | no |
| `settings.changed@1` | `SettingsChangedInput` | `void` | none | 250 ms | yes | ignore | no |
| `command.run@1` | `CommandRunInput` | `CommandResult` | none | 10000 ms | yes | reject | yes |
| `column.values@1` | `ColumnValuesInput` | `ColumnValue[]` | none | 2000 ms | yes | degrade | yes |
| `search.query@1` | `SearchQueryInput` | `SearchBatch` | none | 5000 ms | yes | degrade | yes |
| `preview.render@1` | `PreviewRenderInput` | `PreviewResult` | none | 2000 ms | yes | degrade | yes |
| `location.list@1` | `LocationListInput` | `LocationPage` | none | 5000 ms | yes | degrade | yes |
| `fileop.before.copy@1` | `FileOpBeforeInput` | `OperationDecision` | `operations.intercept (fileOperation: copy)` | 1000 ms | yes | pause | no |
| `fileop.before.move@1` | `FileOpBeforeInput` | `OperationDecision` | `operations.intercept (fileOperation: move)` | 1000 ms | yes | pause | no |
| `fileop.before.trash@1` | `FileOpBeforeInput` | `OperationDecision` | `operations.intercept (fileOperation: trash)` | 1000 ms | yes | pause | no |
| `fileop.before.rename@1` | `FileOpBeforeInput` | `OperationDecision` | `operations.intercept (fileOperation: rename)` | 1000 ms | yes | pause | no |
| `fileop.after.copy@1` | `FileOpAfterInput` | `void` | `operations.observe (fileOperation: copy)` | 2000 ms | yes | ignore | no |
| `fileop.after.move@1` | `FileOpAfterInput` | `void` | `operations.observe (fileOperation: move)` | 2000 ms | yes | ignore | no |
| `fileop.after.trash@1` | `FileOpAfterInput` | `void` | `operations.observe (fileOperation: trash)` | 2000 ms | yes | ignore | no |
| `fileop.after.rename@1` | `FileOpAfterInput` | `void` | `operations.observe (fileOperation: rename)` | 2000 ms | yes | ignore | no |

- `activate@1` — Mod enabled or reloaded; register dynamic state here.
- `deactivate@1` — Mod is being disabled; release resources.
- `selection.changed@1` — Passive selection notification.
- `location.changed@1` — The front window navigated.
- `theme.changed@1` — Theme or appearance changed.
- `settings.changed@1` — A setting of this mod changed.
- `command.run@1` — Run a contributed command.
- `column.values@1` — Cell values for visible items; batched, cached by identity/revision.
- `search.query@1` — Provide search results.
- `preview.render@1` — Render a preview as a native node tree.
- `location.list@1` — List a provided location.
- `fileop.before.copy@1` — Veto a copy before it starts; allow or deny only.
- `fileop.before.move@1` — Veto a move before it starts; allow or deny only.
- `fileop.before.trash@1` — Veto a trash before it starts; allow or deny only.
- `fileop.before.rename@1` — Veto a rename before it starts; allow or deny only.
- `fileop.after.copy@1` — Committed per-item outcomes of a copy; no veto or retry authority.
- `fileop.after.move@1` — Committed per-item outcomes of a move; no veto or retry authority.
- `fileop.after.trash@1` — Committed per-item outcomes of a trash; no veto or retry authority.
- `fileop.after.rename@1` — Committed per-item outcomes of a rename; no veto or retry authority.

### Failure policies

- `reject` — The call rejects with a BFError; an unhandled rejection fails the invoking hook.
- `pause` — Error or timeout pauses the operation before any mutation; only a native user decision may bypass.
- `ignore` — Failures are logged and ignored; the host never retries or repeats work because of them.
- `degrade` — Failures degrade the affected item (placeholder or empty) and mark the contribution unhealthy.

## Bridge functions

Every call is async and must be awaited. 64-bit sizes are decimal strings.

### `ui`

Panels, status text, toolbar state, toasts and native pickers.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `ui.setPanel` | `panelId: string, node: UINode` | `void` | `ui (surfaces: panel)` | 1000 ms | yes | reject | `notFound`, `limitExceeded` |
| `ui.setStatusText` | `itemId: string, text: string` | `void` | `ui (surfaces: statusBar)` | 1000 ms | yes | reject | `notFound` |
| `ui.setToolbarItemState` | `itemId: string, enabled: boolean, title?: string` | `void` | `ui (surfaces: toolbar)` | 1000 ms | yes | reject | `notFound` |
| `ui.notify` | `message: string, level: NotifyLevel` | `void` | none | 1000 ms | yes | reject | `limitExceeded` |
| `ui.pickDestination` (user gesture) | `prompt: string` | `FileRef?` | `fs.write (scope: destination)` | 120000 ms | yes | reject | `noGesture` |

### `commands`

Run and toggle this mod's own commands.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `commands.run` | `commandId: string, args?: json` | `CommandResult?` | none | 10000 ms | yes | reject | `notFound`, `recursionLimit` |
| `commands.setEnabled` | `commandId: string, enabled: boolean` | `void` | none | 1000 ms | yes | reject | `notFound` |

### `fs`

Granted, handle-based file access.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `fs.root` | `rootId: string` | `FileRef?` | `fs.read (scope: root)` | 1000 ms | yes | reject | `notGranted` |
| `fs.stat` | `item: FileRef` | `FileRef` | `fs.read (scope: selection|root)` | 2000 ms | yes | reject | `notFound`, `notGranted`, `staleHandle` |
| `fs.list` (batch ≤ 128) | `directory: FileRef, limit: integer, order: SortOrder, cursor?: string` | `DirectoryPage` | `fs.read (scope: selection|root)` | 2000 ms | yes | reject | `notFound`, `notGranted`, `staleHandle`, `limitExceeded` |
| `fs.walk` (batch ≤ 128) | `directory: FileRef, maxDepth: integer, limit: integer, cursor?: string` | `DirectoryPage` | `fs.read (scope: root; recursive)` | 5000 ms | yes | reject | `notFound`, `notGranted`, `staleHandle`, `limitExceeded` |
| `fs.readText` | `item: FileRef, maxBytes: integer` | `string` | `fs.read (scope: selection|root)` | 2000 ms | yes | reject | `notFound`, `notGranted`, `staleHandle`, `notText` |
| `fs.readBytes` | `item: FileRef, offset: Int64String, length: integer` | `BytesChunk` | `fs.read (scope: selection|root)` | 2000 ms | yes | reject | `notFound`, `notGranted`, `staleHandle`, `limitExceeded` |
| `fs.writeText` | `directory: FileRef, name: string, text: string, conflict: ConflictPolicy` | `FileRef` | `fs.write (scope: selection|root|destination)` | 2000 ms | yes | reject | `notFound`, `notGranted`, `exists`, `invalidName` |
| `fs.mkdir` | `directory: FileRef, name: string` | `FileRef` | `fs.write (scope: selection|root|destination)` | 2000 ms | yes | reject | `notFound`, `notGranted`, `exists`, `invalidName` |

### `operations`

Queued copy/move/trash/rename through the shared file operation queue.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `operations.copy` (user gesture) (batch ≤ 128) | `items: FileRef[], destination: FileRef, conflict: ConflictPolicy` | `OperationTicket` | `fs.read (scope: selection|root)`, `fs.write (scope: destination|root)` | 2000 ms | yes | reject | `notGranted`, `limitExceeded` |
| `operations.move` (user gesture) (batch ≤ 128) | `items: FileRef[], destination: FileRef, conflict: ConflictPolicy` | `OperationTicket` | `fs.read (scope: selection|root)`, `fs.write (scope: destination|root)` | 2000 ms | yes | reject | `notGranted`, `limitExceeded`, `denied` |
| `operations.trash` (user gesture) (batch ≤ 128) | `items: FileRef[]` | `OperationTicket` | `fs.write (scope: selection|root)` | 2000 ms | yes | reject | `notGranted`, `limitExceeded`, `denied` |
| `operations.rename` (user gesture) | `item: FileRef, newName: string` | `OperationTicket` | `fs.write (scope: selection|root)` | 2000 ms | yes | reject | `notGranted`, `invalidName`, `limitExceeded`, `denied` |
| `operations.status` | `operationId: string` | `OperationStatus` | none | 1000 ms | yes | reject | `notFound` |
| `operations.cancel` | `operationId: string` | `boolean` | none | 1000 ms | yes | reject | `notFound` |

### `search`

Host index queries.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `search.files` (batch ≤ 128) | `query: string, root: FileRef, limit: integer, cursor?: string` | `SearchBatch` | `fs.read (scope: root)` | 5000 ms | yes | reject | `notGranted`, `staleHandle`, `limitExceeded` |

### `locations`

Provided (virtual) locations.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `locations.open` | `location: string, path: string` | `void` | `ui (surfaces: location)` | 1000 ms | yes | reject | `notFound` |
| `locations.refresh` | `location: string` | `void` | `ui (surfaces: location)` | 1000 ms | yes | reject | `notFound` |
| `locations.current` | `` | `LocationRef` | none | 1000 ms | yes | reject |  |

### `preview`

Preview refresh and invalidation.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `preview.refresh` | `provider: string, item: FileRef` | `void` | `ui (surfaces: preview)` | 1000 ms | yes | reject | `notFound` |
| `preview.invalidate` | `provider: string` | `void` | `ui (surfaces: preview)` | 1000 ms | yes | reject | `notFound` |

### `media`

Host media helpers.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `media.imageDimensions` (batch ≤ 128) | `items: FileRef[]` | `ColumnValue[]` | `fs.read (scope: selection|root)` | 2000 ms | yes | reject | `notGranted`, `staleHandle`, `limitExceeded` |
| `media.imageInfo` (batch ≤ 128) | `items: FileRef[]` | `ImageInfo[]` | `fs.read (scope: selection|root)` | 2000 ms | yes | reject | `notGranted`, `staleHandle`, `limitExceeded` |

### `net`

Granted network access.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `net.fetch` | `request: NetRequest` | `NetResponse` | `net` | 15000 ms | yes | reject | `notGranted`, `denied`, `timeout`, `limitExceeded`, `network` |

### `process`

Curated broker operations and the high-trust unrestricted escape hatch.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `process.archive.create` (user gesture) (batch ≤ 128) | `items: FileRef[], destination: FileRef, name: string, format: ArchiveFormat` | `OperationTicket` | `fs.read (scope: selection|root)`, `fs.write (scope: destination|root)`, `process.exec (operation: archive.create)` | 2000 ms | yes | reject | `notGranted`, `limitExceeded`, `exists`, `invalidName` |
| `process.git.status` | `root: FileRef` | `GitStatus` | `fs.read (scope: root)`, `process.exec (operation: git.status)` | 5000 ms | yes | reject | `notGranted`, `notARepository`, `timeout` |
| `process.run` (user gesture) | `executable: string, args: string[], cwd?: FileRef` | `ProcessResult` | `process.exec (mode: unrestricted)` | 30000 ms | yes | reject | `notGranted`, `noGesture`, `timeout`, `spawnFailed` |

### `settings`

This mod's own settings.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `settings.get` | `key: string` | `json` | none | 250 ms | yes | reject | `notFound` |
| `settings.getAll` | `` | `json` | none | 250 ms | yes | reject |  |
| `settings.set` | `key: string, value: json` | `void` | none | 1000 ms | yes | reject | `notFound`, `invalidValue` |

### `storage`

Private key/value storage.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `storage.get` | `key: string` | `json` | `storage` | 1000 ms | yes | reject | `notGranted` |
| `storage.set` | `key: string, value: json` | `void` | `storage` | 1000 ms | yes | reject | `notGranted`, `quotaExceeded` |
| `storage.delete` | `key: string` | `void` | `storage` | 1000 ms | yes | reject | `notGranted` |
| `storage.keys` | `` | `string[]` | `storage` | 1000 ms | yes | reject | `notGranted` |

### `credentials`

Opaque, destination-bound Keychain credentials.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `credentials.list` | `` | `CredentialInfo[]` | `credentials` | 1000 ms | yes | reject | `notGranted` |
| `credentials.request` (user gesture) | `name: string, destination: string` | `CredentialHandle?` | `credentials` | 120000 ms | yes | reject | `notGranted`, `denied` |

### `events`

Capability probing and bounded delays.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `events.supports` | `name: string, version: integer` | `boolean` | none | 250 ms | no | reject |  |
| `events.delay` | `ms: integer` | `void` | none | 10500 ms | yes | reject | `limitExceeded` |

### `log`

Logging.

| Function | Parameters | Returns | Requires | Deadline | Cancellable | Failure | Errors |
|---|---|---|---|---|---|---|---|
| `log.write` | `level: LogLevel, message: string, fields?: json` | `void` | none | 250 ms | no | ignore |  |

## Broker operations

- `archive.create` (`process.archive.create`) — Queued archive creation (zip, tar.gz) of granted items into a granted destination.
- `git.status` (`process.git.status`) — Read-only git status for a granted root.

## Types

### `Int64String`

Decimal-string encoding of a 64-bit integer (sizes, offsets).

Alias of `string`.

### `FileKind`

Kind of a file system item.

One of: `file`, `folder`, `symlink`, `other`

### `Appearance`

Effective window appearance.

One of: `light`, `dark`

### `ActivateReason`

Why activate runs.

One of: `startup`, `enable`, `reload`, `update`

### `DeactivateReason`

Why deactivate runs.

One of: `disable`, `uninstall`, `reload`, `update`, `shutdown`

### `LogLevel`

Log severity.

One of: `debug`, `info`, `warn`, `error`

### `NotifyLevel`

Notification severity.

One of: `info`, `warning`, `error`

### `FileOpOrigin`

What initiated a file operation.

One of: `user`, `undo`, `retry`, `mod`, `automation`

### `FileOpStatus`

Committed per-item outcome.

One of: `succeeded`, `failed`, `skipped`, `cancelled`

### `FileOperation`

A guarded file operation.

One of: `copy`, `move`, `trash`, `rename`

### `Decision`

Before-hook verdict.

One of: `allow`, `deny`

### `SortOrder`

Directory listing order.

One of: `name`, `modifiedDescending`, `sizeDescending`

### `ConflictPolicy`

Name conflict resolution.

One of: `fail`, `rename`, `skip`

### `ArchiveFormat`

Archive container format.

One of: `zip`, `tarGz`

### `OperationState`

Queued operation state.

One of: `queued`, `running`, `done`, `failed`, `cancelled`

### `UINodeType`

Native control a UINode maps to.

One of: `vstack`, `hstack`, `text`, `markdown`, `button`, `list`, `progress`, `divider`, `textField`, `select`

### `UITextStyle`

Look of a text node.

One of: `body`, `title`, `secondary`, `monospaced`

### `GitState`

Git working tree state of a path.

One of: `modified`, `added`, `deleted`, `renamed`, `untracked`, `conflicted`

### `HttpMethod`

HTTP method.

One of: `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`

### `HookContext`

First argument of every hook.

| Field | Type | Required | Notes |
|---|---|---|---|
| `modId` | `string` | yes |  |
| `generation` | `integer` | yes | Registration generation; late replies are rejected. |
| `locale` | `string` | yes |  |
| `appearance` | `Appearance` | yes |  |
| `deadlineMs` | `integer` | yes | Remaining time budget. |

### `FileRef`

Reference to a file. Optional fields are populated only when granted.

| Field | Type | Required | Notes |
|---|---|---|---|
| `handle` | `string` | yes | Opaque mod-scoped handle; valid only for the invocation or grant that produced it. |
| `name` | `string` | yes |  |
| `kind` | `FileKind` | yes |  |
| `path` | `string` | no | Requires ui.selection level paths or a root grant. |
| `size` | `Int64String` | no | Requires metadata access. |
| `modified` | `string` | no | ISO-8601; requires metadata access. |

### `DirectoryPage`

One page of directory entries.

| Field | Type | Required | Notes |
|---|---|---|---|
| `entries` | `FileRef[]` | yes |  |
| `cursor` | `string` | no |  |

### `BytesChunk`

A ranged read.

| Field | Type | Required | Notes |
|---|---|---|---|
| `base64` | `string` | yes |  |
| `eof` | `boolean` | yes |  |

### `ColumnValue`

One cell value, keyed by item handle.

| Field | Type | Required | Notes |
|---|---|---|---|
| `handle` | `string` | yes |  |
| `text` | `string` | no |  |
| `number` | `number` | no |  |
| `sortKey` | `string` | no |  |
| `label` | `string` | no |  |

### `ImageInfo`

Image header facts.

| Field | Type | Required | Notes |
|---|---|---|---|
| `handle` | `string` | yes |  |
| `width` | `integer` | yes |  |
| `height` | `integer` | yes |  |
| `format` | `string` | no |  |

### `LocationRef`

A browsable location.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `string` | yes |  |
| `title` | `string` | yes |  |
| `provider` | `string` | no |  |
| `folder` | `FileRef` | no | The folder shown, from locations.current only. Its access follows the mod's grants: fs.write destination during a user gesture, otherwise fs.read/fs.write selection; with neither it is a reference only. |

### `UIListItem`

Row of a list node.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `string` | yes |  |
| `title` | `string` | yes |  |
| `subtitle` | `string` | no |  |

### `UINode`

Data-only description of a native control tree.

| Field | Type | Required | Notes |
|---|---|---|---|
| `type` | `UINodeType` | yes |  |
| `id` | `string` | no |  |
| `text` | `string` | no |  |
| `label` | `string` | no | Accessibility label. |
| `command` | `string` | no | Command run on press; for a textField, run on Return with args {id, value, fields}; for a select, run on change with the chosen item id as value; for a list, run on double-click with the row id as value. Buttons receive args {fields} with the panel's current text field and select values. |
| `style` | `UITextStyle` | no | Look of a text node; body when omitted. |
| `icon` | `string` | no | SF Symbol name drawn on a button. |
| `selected` | `string` | no | Item id a select shows as chosen; the first item when omitted. |
| `placeholder` | `string` | no | Placeholder of a textField; text is its initial value. |
| `value` | `number` | no |  |
| `children` | `UINode[]` | no |  |
| `items` | `UIListItem[]` | no |  |

### `ActivateInput`

activate input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `reason` | `ActivateReason` | yes |  |
| `previousVersion` | `string` | no |  |

### `DeactivateInput`

deactivate input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `reason` | `DeactivateReason` | yes |  |

### `SelectionChangedInput`

selection.changed input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `revision` | `integer` | yes |  |
| `count` | `integer` | yes |  |
| `items` | `FileRef[]` | yes |  |

### `LocationChangedInput`

location.changed input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `revision` | `integer` | yes |  |
| `location` | `LocationRef` | yes |  |

### `ThemeChangedInput`

theme.changed input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | `string` | yes |  |
| `appearance` | `Appearance` | yes |  |

### `SettingsChangedInput`

settings.changed input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `changed` | `string[]` | yes |  |
| `values` | `json` | yes |  |

### `CommandRunInput`

command.run input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `commandId` | `string` | yes |  |
| `selection` | `FileRef[]` | yes |  |
| `args` | `json` | no |  |

### `CommandResult`

command.run result; message is shown as a toast.

| Field | Type | Required | Notes |
|---|---|---|---|
| `message` | `string` | no |  |
| `operationId` | `string` | no |  |

### `ColumnValuesInput`

column.values input; at most 128 items per call.

| Field | Type | Required | Notes |
|---|---|---|---|
| `column` | `string` | yes |  |
| `items` | `FileRef[]` | yes |  |
| `revision` | `integer` | yes |  |

### `SearchQueryInput`

search.query input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `provider` | `string` | yes |  |
| `query` | `string` | yes |  |
| `limit` | `integer` | yes |  |
| `cursor` | `string` | no |  |
| `scope` | `FileRef` | no |  |

### `SearchResult`

One search hit.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `string` | yes |  |
| `title` | `string` | yes |  |
| `subtitle` | `string` | no |  |
| `handle` | `string` | no |  |

### `SearchBatch`

A page of search results.

| Field | Type | Required | Notes |
|---|---|---|---|
| `results` | `SearchResult[]` | yes |  |
| `done` | `boolean` | yes |  |
| `cursor` | `string` | no |  |

### `PreviewRenderInput`

preview.render input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `provider` | `string` | yes |  |
| `item` | `FileRef` | yes |  |
| `maxBytes` | `integer` | yes |  |
| `appearance` | `Appearance` | yes |  |

### `PreviewResult`

preview.render result.

| Field | Type | Required | Notes |
|---|---|---|---|
| `title` | `string` | no |  |
| `node` | `UINode` | yes |  |

### `LocationListInput`

location.list input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `location` | `string` | yes |  |
| `path` | `string` | yes | Virtual path; empty for the root. |
| `limit` | `integer` | yes |  |
| `cursor` | `string` | no |  |

### `ResourceEntry`

Entry of a provided location.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | `string` | yes |  |
| `name` | `string` | yes |  |
| `kind` | `FileKind` | yes |  |
| `size` | `Int64String` | no |  |
| `modified` | `string` | no |  |

### `LocationPage`

location.list result.

| Field | Type | Required | Notes |
|---|---|---|---|
| `items` | `ResourceEntry[]` | yes |  |
| `cursor` | `string` | no |  |

### `FileOpItem`

One item of an operation.

| Field | Type | Required | Notes |
|---|---|---|---|
| `itemId` | `string` | yes |  |
| `source` | `FileRef` | yes |  |
| `destinationName` | `string` | no |  |

### `FileOpBeforeInput`

fileop.before.* input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `operationId` | `string` | yes |  |
| `attemptId` | `string` | yes |  |
| `origin` | `FileOpOrigin` | yes |  |
| `operation` | `FileOperation` | yes |  |
| `items` | `FileOpItem[]` | yes |  |

### `OperationDecision`

fileop.before.* result.

| Field | Type | Required | Notes |
|---|---|---|---|
| `decision` | `Decision` | yes |  |
| `reason` | `string` | no |  |

### `FileOpOutcome`

Committed outcome for one item.

| Field | Type | Required | Notes |
|---|---|---|---|
| `itemId` | `string` | yes |  |
| `source` | `FileRef` | yes |  |
| `status` | `FileOpStatus` | yes |  |
| `error` | `string` | no |  |

### `FileOpAfterInput`

fileop.after.* input.

| Field | Type | Required | Notes |
|---|---|---|---|
| `operationId` | `string` | yes |  |
| `attemptId` | `string` | yes |  |
| `origin` | `FileOpOrigin` | yes |  |
| `operation` | `FileOperation` | yes |  |
| `partial` | `boolean` | yes |  |
| `outcomes` | `FileOpOutcome[]` | yes |  |

### `OperationTicket`

Queued operation identity.

| Field | Type | Required | Notes |
|---|---|---|---|
| `operationId` | `string` | yes |  |

### `OperationStatus`

Progress of a queued operation.

| Field | Type | Required | Notes |
|---|---|---|---|
| `operationId` | `string` | yes |  |
| `state` | `OperationState` | yes |  |
| `completed` | `integer` | yes |  |
| `total` | `integer` | yes |  |

### `HttpHeader`

One HTTP header.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | `string` | yes |  |
| `value` | `string` | yes |  |

### `NetRequest`

Outgoing request; must match a granted endpoint.

| Field | Type | Required | Notes |
|---|---|---|---|
| `url` | `string` | yes |  |
| `method` | `HttpMethod` | yes |  |
| `headers` | `HttpHeader[]` | no |  |
| `body` | `string` | no |  |
| `timeoutMs` | `integer` | no |  |
| `credential` | `string` | no | Credential handle from credentials.request. |

### `NetResponse`

Incoming response; bodies are capped by the grant.

| Field | Type | Required | Notes |
|---|---|---|---|
| `status` | `integer` | yes |  |
| `headers` | `HttpHeader[]` | yes |  |
| `body` | `string` | yes |  |

### `CredentialHandle`

Opaque destination-bound Keychain credential.

| Field | Type | Required | Notes |
|---|---|---|---|
| `handle` | `string` | yes |  |
| `destination` | `string` | yes |  |

### `CredentialInfo`

Credential metadata without secret material.

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | `string` | yes |  |
| `destination` | `string` | yes |  |

### `GitStatusEntry`

One changed path.

| Field | Type | Required | Notes |
|---|---|---|---|
| `path` | `string` | yes |  |
| `state` | `GitState` | yes |  |

### `GitStatus`

Curated git status result.

| Field | Type | Required | Notes |
|---|---|---|---|
| `branch` | `string` | no |  |
| `entries` | `GitStatusEntry[]` | yes |  |

### `ProcessResult`

Result of an unrestricted process.

| Field | Type | Required | Notes |
|---|---|---|---|
| `exitCode` | `integer` | yes |  |
| `stdout` | `string` | yes |  |
| `stderr` | `string` | yes |  |

## Diagnostic codes

| Code | Severity | Meaning |
|---|---|---|
| `BF1001` | error | Invalid JSON |
| `BF1002` | error | Unknown key in closed object |
| `BF1003` | error | Missing required key |
| `BF1004` | error | Wrong JSON type |
| `BF1005` | error | Invalid value |
| `BF1006` | error | Unsupported manifest version |
| `BF1007` | error | Invalid mod id |
| `BF1008` | error | Invalid semantic version or range |
| `BF1009` | error | Size bound exceeded |
| `BF1010` | error | JSON Schema violation |
| `BF1011` | error | Duplicate id |
| `BF1012` | error | Reserved id namespace |
| `BF1013` | error | Mod id is not namespaced by its author |
| `BF2001` | error | Unknown script construct |
| `BF2002` | error | Malformed script program |
| `BF2003` | error | Unsupported script format version |
| `BF2004` | error | Invalid identifier |
| `BF2005` | error | Literal out of range |
| `BF2010` | error | Unknown hook signature |
| `BF2011` | error | Unsupported hook signature version |
| `BF2012` | error | Unknown function |
| `BF2013` | error | Wrong number of arguments |
| `BF2014` | error | Type mismatch |
| `BF2015` | error | Unknown variable |
| `BF2016` | error | Duplicate or shadowing variable |
| `BF2017` | error | Unknown record field |
| `BF2018` | error | Async call not awaited |
| `BF2019` | error | Missing return on some path |
| `BF2020` | error | Loop without a valid bound |
| `BF2021` | error | Loop bound exceeds limit |
| `BF2022` | error | Recursive call |
| `BF2023` | error | Call depth exceeded |
| `BF2024` | error | Script size or nesting limit exceeded |
| `BF2026` | error | Optional value used without unwrap |
| `BF2028` | error | Unknown type |
| `BF2029` | error | Value is not a list |
| `BF2030` | error | Reserved name |
| `BF2031` | error | Assignment to a read-only variable |
| `BF3001` | warning | Unreachable code |
| `BF3002` | warning | Unused variable |
| `BF3003` | warning | Loop without cancellation check |
| `BF3004` | warning | Unused function |
| `BF4001` | error | Required grant not declared |
| `BF4002` | warning | Declared grant never used |
| `BF4003` | warning | Duplicate grant |
| `BF4004` | error | Local or private network destination needs allowPrivate |
| `BF4005` | warning | Plain HTTP endpoint |
| `BF4006` | warning | Unrestricted process execution |
| `BF4007` | error | Unknown broker operation |
| `BF4008` | error | Invalid grant shape |
| `BF4009` | warning | Secret-like setting should use credentials |
| `BF4010` | error | Root id not declared by any grant |
| `BF5001` | error | Forbidden file type in package |
| `BF5002` | error | Package has no manifest.json |
| `BF5003` | error | Path escapes the package |
| `BF5004` | error | Referenced path does not exist |
| `BF5005` | error | Duplicate or case-colliding path |
| `BF5006` | error | Package too large |
| `BF5010` | error | data/1 mods must not declare an entry |
| `BF5011` | error | Entry missing or wrong extension for runtime |
| `BF5012` | error | data/1 mods cannot declare handlers or hooks |
| `BF5020` | error | Mod depends on itself |
| `BF5021` | error | Dependency listed as conflict |
| `BF5022` | error | Dependency cycle |
| `BF5023` | error | Conflicting mods installed together |
| `BF5024` | error | Dependency missing or hash mismatch |
| `BF5030` | error | Archive entry path escapes the package |
| `BF5031` | error | Archive entry is a symbolic link |
| `BF5032` | error | Archive entry is a device, socket or FIFO |
| `BF5033` | error | Archive entry has an executable permission bit |
| `BF5034` | error | Archive expansion ratio exceeds limit |
| `BF5035` | error | Archive or entry size cap exceeded |
| `BF5036` | error | Archive contains a duplicate entry |
| `BF5037` | error | Archive entry is encrypted |
| `BF5038` | error | Archive uses unsupported ZIP64 structures |
| `BF5039` | error | Archive entry name disagrees between headers |
| `BF6001` | error | API range excludes host API |
| `BF6002` | error | App range excludes host app |
| `BF6003` | warning | Version range has no upper bound |
| `BF7001` | error | Unknown reference |
| `BF7002` | error | Handler function not found in script |
| `BF7003` | error | Handler is not bound to the right hook |
| `BF7004` | warning | Hook handler never referenced |
| `BF7005` | error | Unknown hook |
| `BF7006` | error | Unsupported hook version |
| `BF7007` | error | Duplicate hook |
| `BF7008` | error | Duplicate keybinding |
| `BF7009` | warning | Keybinding without command/control/option modifier |
| `BF7010` | error | Index listing does not match manifest |
| `BF7011` | error | Release signature does not verify |
| `BF7012` | error | Release key is not a trusted key of the author |
| `BF7013` | error | Release artifact does not match the listing |
| `BF8001` | error | TypeScript type error |
| `BF8002` | error | TypeScript syntax error |
| `BF8003` | error | Script violates the sandbox policy |
| `BF8004` | error | Catalog accessed dynamically |
| `BF8005` | error | Dry run failed |
| `BF8006` | error | Dry run timed out |
| `BF8007` | error | Script host crashed during dry run |
| `BF9001` | error | Internal validator disagreement |
| `BF9002` | info | Check not run |
