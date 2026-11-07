# Manifest reference

Generated from the manifest JSON Schema (`urn:betterfinder:schema:mod-manifest:1`). Objects are closed: unknown keys are errors. `entry` is required for every runtime except `data/1`, where it is forbidden.

## Manifest

| Field | Type | Required |
|---|---|---|
| `api` | `semverRange` | yes |
| `app` | `semverRange` | yes |
| `author` | string, pattern `^[A-Za-z0-9][A-Za-z0-9-]{0,38}$` | yes |
| `conflicts` | array of `modId` (max 16) (unique) | yes |
| `contributes` | `contributes` | yes |
| `dependencies` | array of `dependency` (max 16) | yes |
| `entry` | `relPath` | no |
| `hooks` | array of `hook` (max 128) | yes |
| `id` | `modId` | yes |
| `license` | string, min length 1, max length 64 | yes |
| `manifestVersion` | const `1` | yes |
| `name` | string, min length 1, max length 80 | yes |
| `permissions` | array of `permission` (max 64) | yes |
| `runtime` | `data/1` \| `jsc-ir/1` \| `js/1` \| `ts/1` | yes |
| `settings` | array of `setting` (max 128) | yes |
| `version` | `semver` | yes |

## Runtimes

| Runtime | Entry extension | Language |
|---|---|---|
| `data/1` | none | none (declarative only) |
| `jsc-ir/1` | `.bfscript.json` | typed JSON (bfscript) |
| `js/1` | `.js`, `.mjs` | JavaScript |
| `ts/1` | `.ts` | TypeScript |

## Definitions

### `assetSet`

| Field | Type | Required |
|---|---|---|
| `id` | `localId` | yes |
| `path` | `relPath` | yes |
| `title` | `title` | yes |

### `builtinId`

string, pattern `^builtin\.[a-z0-9][a-z0-9.-]{0,63}$`

### `column`

| Field | Type | Required |
|---|---|---|
| `handler` | `handler` | yes |
| `id` | `localId` | yes |
| `replaces` | `builtinId` | no |
| `sortable` | boolean | no |
| `title` | `title` | yes |
| `valueType` | `string` \| `number` \| `bytes` \| `date` \| `boolean` | yes |
| `width` | integer, min 40, max 1000 | no |

### `command`

| Field | Type | Required |
|---|---|---|
| `category` | string, min length 1, max length 40 | no |
| `handler` | `handler` | yes |
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `title` | `title` | yes |

### `commandRef`

string, pattern `^([a-z][a-z0-9-]{0,47}\|builtin\.[a-z0-9][a-z0-9.-]{0,63})$`

### `contextMenuItem`

| Field | Type | Required |
|---|---|---|
| `command` | `commandRef` | yes |
| `id` | `localId` | yes |
| `replaces` | `builtinId` | no |
| `target` | `items` \| `background` | yes |
| `title` | `title` | yes |

### `contributes`

| Field | Type | Required |
|---|---|---|
| `columns` | array of `column` (max 64) | no |
| `commands` | array of `command` (max 64) | no |
| `contextMenu` | array of `contextMenuItem` (max 64) | no |
| `iconSets` | array of `assetSet` (max 64) | no |
| `keybindings` | array of `keybinding` (max 64) | no |
| `locations` | array of `location` (max 64) | no |
| `panels` | array of `panel` (max 64) | no |
| `previews` | array of `preview` (max 64) | no |
| `searchProviders` | array of `searchProvider` (max 64) | no |
| `settingsPanes` | array of `settingsPane` (max 64) | no |
| `sidebarSections` | array of `sidebarSection` (max 64) | no |
| `sounds` | array of `assetSet` (max 64) | no |
| `statusBar` | array of `statusBarItem` (max 64) | no |
| `themes` | array of `theme` (max 64) | no |
| `toolbar` | array of `toolbarItem` (max 64) | no |
| `views` | array of `view` (max 64) | no |

### `dependency`

| Field | Type | Required |
|---|---|---|
| `id` | `modId` | yes |
| `sha256` | `sha256` | yes |
| `version` | `semver` | yes |

### `handler`

string, pattern `^[a-zA-Z_][a-zA-Z0-9_]{0,63}$`

### `hook`

| Field | Type | Required |
|---|---|---|
| `handler` | `handler` | yes |
| `name` | string, pattern `^[a-z]+(\.[a-z]+)*$`, max length 64 | yes |
| `version` | integer, min 1, max 1000 | yes |

### `icon`

string, pattern `^[A-Za-z0-9.]{1,64}$`

### `keybinding`

| Field | Type | Required |
|---|---|---|
| `command` | `commandRef` | yes |
| `id` | `localId` | yes |
| `key` | string, pattern `^(?:(?:cmd\|ctrl\|opt\|shift)\+){0,4}(?:[a-z0-9]\|f(?:[1-9]\|1[0-9]\|20)\|space\|return\|tab\|delete\|escape\|up\|down\|left\|right\|\[\|\]\|,\|\.\|/\|-\|=)$` | yes |

### `localId`

string, pattern `^[a-z][a-z0-9-]{0,47}$`

### `location`

| Field | Type | Required |
|---|---|---|
| `handler` | `handler` | yes |
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `readOnly` | boolean | yes |
| `scheme` | string, pattern `^[a-z][a-z0-9-]{1,23}$` | yes |
| `title` | `title` | yes |

### `modId`

string, pattern `^[a-z0-9][a-z0-9.-]{2,95}$`

### `netEndpoint`

| Field | Type | Required |
|---|---|---|
| `host` | string, pattern `^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$` | yes |
| `methods` | array of `GET` \| `HEAD` \| `POST` \| `PUT` \| `PATCH` \| `DELETE` (max 6) (unique) | yes |
| `port` | integer, min 1, max 65535 | no |
| `scheme` | `https` \| `http` | yes |

### `panel`

| Field | Type | Required |
|---|---|---|
| `edge` | `left` \| `right` \| `bottom` | yes |
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `presentation` | `docked` \| `slideOut` | yes |
| `title` | `title` | yes |

### `permCredentials`

| Field | Type | Required |
|---|---|---|
| `destinations` | array of string, pattern `^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$` (max 16) (unique) | yes |
| `kind` | const `"credentials"` | yes |
| `reason` | `reason` | yes |

### `permFsRead`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"fs.read"` | yes |
| `reason` | `reason` | yes |
| `recursive` | boolean | no |
| `rootId` | string, pattern `^[a-z][a-z0-9-]{0,31}$` | no |
| `scope` | `selection` \| `root` | yes |

### `permFsWrite`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"fs.write"` | yes |
| `reason` | `reason` | yes |
| `recursive` | boolean | no |
| `rootId` | string, pattern `^[a-z][a-z0-9-]{0,31}$` | no |
| `scope` | `selection` \| `root` \| `destination` | yes |

### `permNet`

| Field | Type | Required |
|---|---|---|
| `allowPrivate` | boolean | no |
| `endpoints` | array of `netEndpoint` (max 32) | yes |
| `kind` | const `"net"` | yes |
| `maxBytes` | integer, min 1, max 268435456 | no |
| `reason` | `reason` | yes |

### `permOpsIntercept`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"operations.intercept"` | yes |
| `operations` | array of `copy` \| `move` \| `trash` \| `rename` (max 4) (unique) | yes |
| `reason` | `reason` | yes |

### `permOpsObserve`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"operations.observe"` | yes |
| `operations` | array of `copy` \| `move` \| `trash` \| `rename` (max 4) (unique) | yes |
| `reason` | `reason` | yes |

### `permProcessExec`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"process.exec"` | yes |
| `mode` | `broker` \| `unrestricted` | yes |
| `operations` | array of string, pattern `^[a-z][a-z0-9]*(\.[a-z][a-zA-Z0-9]*)+$` (max 16) (unique) | no |
| `reason` | `reason` | yes |

### `permStorage`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"storage"` | yes |
| `quotaBytes` | integer, min 1024, max 16777216 | no |

### `permUi`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"ui"` | yes |
| `surfaces` | array of `surface` (max 10) (unique) | yes |

### `permUiOverride`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"ui.override"` | yes |
| `reason` | `reason` | yes |
| `surfaces` | array of `surface` (max 10) (unique) | yes |

### `permUiSelection`

| Field | Type | Required |
|---|---|---|
| `kind` | const `"ui.selection"` | yes |
| `level` | `names` \| `paths` \| `metadata` | yes |
| `reason` | `reason` | yes |

### `permission`

| Field | Type | Required |
|---|---|---|
| `kind` | `fs.read` \| `fs.write` \| `net` \| `process.exec` \| `ui` \| `ui.override` \| `ui.selection` \| `credentials` \| `storage` \| `operations.observe` \| `operations.intercept` | yes |

### `preview`

| Field | Type | Required |
|---|---|---|
| `extensions` | array of string, pattern `^[a-z0-9]{1,16}$` (max 32) (unique) | yes |
| `handler` | `handler` | yes |
| `id` | `localId` | yes |
| `replaces` | `builtinId` | no |
| `title` | `title` | yes |

### `reason`

string, min length 1, max length 400

### `relPath`

string, pattern `^(?!/)(?!.*(^\|/)\.\.?(/\|$))(?!.*//)(?!.*\\)[^\u0000-\u001f]{1,240}$`

### `searchProvider`

| Field | Type | Required |
|---|---|---|
| `handler` | `handler` | yes |
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `title` | `title` | yes |

### `semver`

string, pattern `^(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$`, max length 128

### `semverRange`

string, pattern `^ *(?:>=\|<=\|>\|<\|=\|\^\|~)?(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?(?: +(?:>=\|<=\|>\|<\|=\|\^\|~)?(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)*(?: *\\|\\| *(?:>=\|<=\|>\|<\|=\|\^\|~)?(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?(?: +(?:>=\|<=\|>\|<\|=\|\^\|~)?(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})\.(?:0\|[1-9][0-9]{0,8})(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)*)* *$`, max length 128

### `setting`

| Field | Type | Required |
|---|---|---|
| `default` | any | yes |
| `description` | string, min length 1, max length 400 | no |
| `key` | string, pattern `^[a-z][a-zA-Z0-9_]{0,47}$` | yes |
| `label` | string, min length 1, max length 80 | yes |
| `maxLength` | integer, min 0, max 4096 | no |
| `maximum` | number | no |
| `minimum` | number | no |
| `options` | array of `settingOption` (max 64) | no |
| `type` | `boolean` \| `integer` \| `number` \| `string` \| `enum` | yes |

### `settingOption`

| Field | Type | Required |
|---|---|---|
| `label` | string, min length 1, max length 80 | yes |
| `value` | string, min length 1, max length 80 | yes |

### `settingsPane`

| Field | Type | Required |
|---|---|---|
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `settings` | array of string, pattern `^[a-z][a-zA-Z0-9_]{0,47}$` (max 128) (unique) | yes |
| `title` | `title` | yes |

### `sha256`

string, pattern `^[0-9a-f]{64}$`

### `sidebarItem`

| Field | Type | Required |
|---|---|---|
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `knownFolder` | `home` \| `desktop` \| `documents` \| `downloads` \| `applications` \| `pictures` \| `movies` \| `music` | no |
| `location` | `localId` | no |
| `title` | `title` | yes |

### `sidebarSection`

| Field | Type | Required |
|---|---|---|
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `items` | array of `sidebarItem` (max 32) | yes |
| `replaces` | `builtinId` | no |
| `title` | `title` | yes |

### `statusBarItem`

| Field | Type | Required |
|---|---|---|
| `alignment` | `leading` \| `trailing` | no |
| `command` | `commandRef` | no |
| `id` | `localId` | yes |
| `replaces` | `builtinId` | no |
| `title` | `title` | yes |

### `surface`

`toolbar` \| `sidebar` \| `contextMenu` \| `column` \| `statusBar` \| `panel` \| `preview` \| `view` \| `location` \| `search`

### `theme`

| Field | Type | Required |
|---|---|---|
| `appearance` | `light` \| `dark` \| `any` | yes |
| `id` | `localId` | yes |
| `path` | `relPath` | yes |
| `title` | `title` | yes |

### `title`

string, min length 1, max length 80

### `toolbarItem`

| Field | Type | Required |
|---|---|---|
| `command` | `commandRef` | yes |
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `replaces` | `builtinId` | no |
| `title` | `title` | yes |

### `view`

| Field | Type | Required |
|---|---|---|
| `columns` | array of `localId` (max 32) (unique) | no |
| `icon` | `icon` | no |
| `id` | `localId` | yes |
| `layout` | `list` \| `grid` \| `columns` | yes |
| `replaces` | `builtinId` | no |
| `title` | `title` | yes |
