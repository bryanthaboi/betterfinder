# Permissions

Declare grants in `manifest.json`. Use the smallest scope that reaches the requested action and explain why. A contribution declaration is not file access. Capability probing (`events.supports`) is not authorization.

| Kind | Fields and authority |
| --- | --- |
| `fs.read` | `scope`, `reason`; optional `recursive`, `rootId`. Read granted selection or a user-picked root. |
| `fs.write` | `scope`, `reason`; optional `recursive`, `rootId`. Write through selection, chosen destination or root handles. |
| `ui` | `surfaces`. Add contributions to named surfaces. |
| `ui.override` | `surfaces`, `reason`. Override built-in contributions; broader than adding your own. |
| `ui.selection` | `level`, `reason`. Passive selection notifications at `names`, `paths` or `metadata` level. |
| `process.exec` | `mode`, `reason`; optional `operations`. `broker` allows named operations; `unrestricted` allows full user-account execution. |
| `net` | `endpoints`, `reason`; optional `allowPrivate`, `maxBytes`. Endpoints specify scheme, host, optional port and allowed methods. |
| `credentials` | `destinations`, `reason`. Opaque destination-bound Keychain handles, never raw secret strings. |
| `storage` | Optional `quotaBytes`. Private JSON key/value storage, not arbitrary disk access. |
| `operations.observe` | `operations`, `reason`. Observe committed copy/move/trash/rename outcomes. |
| `operations.intercept` | `operations`, `reason`. Allow or deny those operations before execution. |

Filesystem scopes are `selection` (invocation/gesture-bound items), `root` (a user-chosen folder bound to `rootId`) and `destination` (native destination picker). Reads generally require selection or root; destination is for writing. Recursive access must be explicit. `fs.root("downloads")` resolves the root the user bound to that identifier; it does not silently grant the real Downloads folder. Handles expire and cannot be shared across mods or generations.

Curated execution operations are `archive.create` and `git.status`. Queued work is capped: `operations.copy`, `move`, `trash`, `rename` and `process.archive.create` return `limitExceeded` while a mod has 128 operations queued or running, or all mods together have 512. `process.git.status` is a function name, not a permission kind: request `process.exec` in broker mode with `operations: ["git.status"]`, plus root read access. Unrestricted execution is high trust: executable code has the account's authority, beyond handle-based filesystem scopes. It produces warning `BF4006` and requires native approval. Prefer brokers whenever possible.

Network requests must match the destination and method. Private networks need explicit allowance; HTTP triggers a warning. DNS and redirects require runtime rechecks. Each connection goes only to addresses that passed the check, and every redirect is checked again before any bytes are sent. Requests send `Accept-Encoding: identity`, a stored credential is never forwarded to a different host on redirect, header names must be valid HTTP tokens (`Keep-Alive`, `Proxy-Connection` and `Trailer` are refused), and the timeout covers the whole request. Responses must be well formed: a transfer coding other than plain `chunked`, bad chunk framing, or conflicting or duplicate `Content-Length` headers fail the request. Credential destinations must match their use; keep secrets out of settings, source, screenshots and release archives.

The native install flow presents publisher/package information, requested grants and reasons, preflight diagnostics, and a separate enable decision. Users choose roots/destinations; code and clients cannot grant themselves approval. Broader update permissions or changed author keys require renewed consent. Disable removes registrations and revokes runtime authority. Uninstall retains private data unless deletion is selected.

See [manifest fields](reference/Reference-Manifest.md), [hooks](hooks.md) and [troubleshooting](troubleshooting.md).
