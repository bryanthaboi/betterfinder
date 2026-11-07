# Writing mods in bfscript

bfscript is typed JSON, not JavaScript embedded in JSON. Use `runtime: "jsc-ir/1"`, an entry ending in `.bfscript.json`, and `format: 1`. A function bound to a hook uses its versioned signature. Hook arguments are `context` and `input`.

This complete program supplies an image-dimensions column; the manifest must also declare the column, bind its handler, and grant selection reads plus column UI access.

```json
{"format":1,"functions":{"dimensions":{"signature":"column.values@1","body":[
  {"return":{"await":{"call":"media.imageDimensions","args":[{"get":["input","items"]}]}}}
]}}}
```

Strings, numbers, booleans and null are literals. Wrap object construction in `record`, lists in `list`, and variable/field reads in `get`. Paths may include list indexes. `call` invokes a catalog function; `fn` invokes a local helper. Async catalog calls must be inside `await`.

Statements are `let` (optional explicit `type`), `set`, `append`, `if` with `then` and optional `else`, `forEach`, `return`, `do`, `fail`, and `checkCancelled`. Use `do` for a result you do not return. Variables cannot shadow existing bindings; `context` and `input` are reserved.

```json
{"if":{"isNull":{"get":["root"]}},"then":[{"return":{"record":{"items":{"list":[]}}}}]}
```

Check nullable results before `unwrap`. A declared type can be a catalog type name, a primitive, or a structured list/optional type. The checker requires compatible record fields and a return on every non-void path. Helpers must not recurse.

Loops require a literal `max` within the catalog bound; include `{"checkCancelled":true}` in each loop body. See [Recent Downloads](../../examples/recent-downloads/scripts/main.bfscript.json) for a bounded list transformation, optional-root handling and record construction. That example intentionally shows only one page.

Operators include comparisons (`eq`, `lt`, `ge`), arithmetic (`add`, `sub`, `mul`, `div`), boolean (`and`, `or`, `not`), strings (`concat`, `trim`, `startsWith`, `endsWith`, `substring`, `replace`), collections (`length`, `index`, `slice`) and optionals (`isNull`, `unwrap`, `coalesce`). No arbitrary properties, code evaluation, unbounded loops or native filesystem APIs are available.

Use [Zip Selection](../../examples/zip-selection/README.md) for a command and destination picker. Validate after each edit; [diagnostics](troubleshooting.md) identify a JSON pointer and a fix. Consult [catalog types and limits](reference/Reference-API.md) rather than inventing fields.

## Author tests

Script packages can include `tests/*.bftest.json` files, one test per file, directly in `tests/` (no subfolders, at most 64 files, 64 KiB each). `betterfinder-mod validate` and the app's preflight run them in the dry run and fail with `BF8005` when one doesn't match. Data-only packages can't have tests.

```json
{
  "name": "trailing-space",
  "hook": "fileop.before.rename",
  "handler": "guardRename",
  "input": {
    "operationId": "op",
    "attemptId": "attempt",
    "origin": "user",
    "operation": "rename",
    "items": [
      { "itemId": "one", "source": { "handle": "file-1", "name": "old", "kind": "file" }, "destinationName": "report " }
    ]
  },
  "expect": { "equals": { "decision": "deny", "reason": "Names must not end with a space." } }
}
```

| Field | Meaning |
| --- | --- |
| `hook` | Required. A hook your manifest declares. |
| `input` | Required. The hook's input, typed by the catalog. |
| `expect` | Required. Exactly one of `equals`, `contains`, `matches` (regex against a string result) or `error` (`true`, or text the error message must contain). |
| `name` | Optional label shown in failures. Must be unique. |
| `version` | Optional hook version, default 1. |
| `handler` | Needed only when several handlers bind the same hook. |

A failure looks like this:

```text
FAIL examples.rename-guard 1.0.0
tests/trailing-space.bftest.json: error BF8005: dry run: author test tests/trailing-space.bftest.json: trailing-space failed: expected {"decision":"deny","reason":"wrong"}, got {"decision":"deny","reason":"Names must not end with a space."}
checks: ... dryRun=fail
```

See [Rename Guard tests](../../examples/rename-guard/tests/trailing-space.bftest.json) and [Zip Selection empty input](../../examples/zip-selection/tests/empty-selection.bftest.json). Manual visible-effect checklists under each example's `fixtures/` are separate and are not run automatically.
