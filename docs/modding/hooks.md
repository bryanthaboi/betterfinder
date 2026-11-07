# Hooks

Declare `{ "name": "column.values", "handler": "dimensions", "version": 1 }` in `hooks`. TS/JS handlers are exported functions `(context, input)`; bfscript functions declare `signature: "column.values@1"`. Bind contribution handlers to the correct hook.

| Hook | Deadline | Failure behavior |
| --- | --- | --- |
| `activate` | 2000 ms | Reject activation; not cancellable. |
| `deactivate` | 1000 ms | Ignore failure; not cancellable. |
| `selection.changed` | 250 ms | Ignore; requires `ui.selection`. |
| `location.changed` | 250 ms | Ignore. |
| `theme.changed` | 250 ms | Ignore. |
| `settings.changed` | 250 ms | Ignore. |
| `command.run` | 10000 ms | Reject command. |
| `column.values` | 2000 ms | Degrade the contribution; at most 128 items per call. |
| `search.query` | 5000 ms | Degrade search. |
| `preview.render` | 2000 ms | Degrade preview. |
| `location.list` | 5000 ms | Degrade listing. |
| `fileop.before.copy`, `fileop.before.move`, `fileop.before.trash`, `fileop.before.rename` | 1000 ms | Pause the operation for native resolution. |
| `fileop.after.copy`, `fileop.after.move`, `fileop.after.trash`, `fileop.after.rename` | 2000 ms | Ignore observer failure; operation already committed. |

These are catalog v1 deadlines, not permission to block a synchronous JS turn. The host also enforces a 250 ms synchronous watchdog. A long broker deadline does not extend the calling hook's budget. Use batched asynchronous calls, cancellation checks and bounded work.

Before hooks require `operations.intercept` for the specific operation and return `{decision:"allow"}` or `{decision:"deny",reason:"..."}`. They cannot rewrite paths, retry or perform the operation themselves. A timeout is not permission to silently proceed. Input contains operation/attempt identity, origin and items with optional `destinationName`.

After hooks require `operations.observe`. They receive committed per-item statuses (`succeeded`, `failed`, `skipped`, `cancelled`), errors and `partial`; they cannot veto or undo an outcome. Distinguish `operationId` from `attemptId`, and handle origins `user`, `undo`, `retry`, `mod`, `automation` without recursive side effects.

The host rejects late replies from older generations. Most hooks are cancellable; the catalog identifies exceptions and exact input/output types. See [API reference](reference/Reference-API.md) and [Rename Guard](../../examples/rename-guard/README.md).
