# MCPServer

Model Context Protocol server that lets a client author, test, package and (with the user's approval) publish betterfinder mods. It sits on `ModKit` (catalog, schemas, diagnostics) and `ModValidation` (the one shared preflight, scaffolds, packaging, index listings). The running app is reached through an injected `LiveModHosting`, so the same server runs inside the app or from the `betterfinder-mod mcp` CLI.

Protocol: JSON-RPC 2.0, MCP `2025-11-25` / `2025-06-18` (negotiated), tools, resources, prompts, pagination, cancellation. Transports: stdio (newline-delimited, stdout is protocol only, logs go to stderr) and Streamable HTTP on `127.0.0.1` only.

## Run it

```sh
swift build -c release --package-path Packages/ModValidation --product betterfinder-mod
BF=$PWD/Packages/ModValidation/.build/release/betterfinder-mod

$BF mcp                 # stdio (default), live tools reach the app through ~/Library/Application Support/betterfinder/mcp.json
$BF mcp --no-live       # stdio, live tools disabled
$BF mcp --http          # 127.0.0.1:<random port>, bearer token in mcp-cli.json (mode 0600)
```

Options: `--port n`, `--token-file path`, `--workspaces dir`, `--allow-origin url` (repeatable), `--no-live`.

Workspaces live in `~/Library/Application Support/betterfinder/ModWorkspaces/<mod id>`. Packages and screenshots are written to `ModWorkspaces/.artifacts/<mod id>/`, outside the package tree, so they are never packaged or published.

## Client configuration

### stdio clients

```json
{
  "mcpServers": {
    "betterfinder-mod": {
      "command": "/absolute/path/to/betterfinder-mod",
      "args": ["mcp"]
    }
  }
}
```

### Streamable HTTP (app endpoint or `mcp --http`)

The app (after Mods → Start MCP Server) and `betterfinder-mod mcp --http` both write a pairing file; the URL and token are in it. The token is never put on a command line by betterfinder, and every request must send it.


```json
{
  "mcpServers": {
    "betterfinder": {
      "type": "http",
      "url": "http://127.0.0.1:PORT/mcp",
      "headers": { "Authorization": "Bearer TOKEN" }
    }
  }
}
```

The token changes whenever the app restarts or the token is rotated; re-read the file.

HTTP rules: loopback bind only, `Host` must be `127.0.0.1:<port>`, `localhost:<port>` or `[::1]:<port>` (otherwise 403), a present `Origin` must be the server's own (otherwise 403, checked before auth), missing or wrong bearer is 401, bodies are capped at 1 MiB, `Mcp-Session-Id` is routing only and never authentication.

## Tools

All results are `{ok:true,data}` or `{ok:false,error:{code,message,diagnostics?}}` in `structuredContent` (and as text). Classes: R reads, W edits the workspace, L touches the running app, P is an external publication and needs consent.

| Tool | Class | What it does |
|---|---|---|
| `mod_api` | R | catalog, hooks, schemas and docs of the installed API, paged |
| `mod_scaffold` | W | tested template, `language: bfscript \| ts \| js`, returns `authoringPrompt` |
| `mod_files_list`, `mod_files_read` | R | workspace only, UTF-8 text |
| `mod_files_write` | W | atomic, expected revision, no escapes or links, `text: null` deletes |
| `mod_validate` | W | shared preflight on an isolated snapshot, returns diagnostics and a `receipt` when there are no errors |
| `mod_load`, `mod_unload` | L | hot-load into the running app (developer mode), reload by calling again |
| `mod_ui_state`, `mod_screenshot`, `mod_logs` | L / R | filtered window state, PNG of the app's own window (also returned inline as an image), bounded redacted logs |
| `mod_package` | W | reproducible `.bfmod`, requires a receipt for the exact revision |
| `github_create_repo` | P | `gh repo create`, empty repository |
| `github_publish_release` | P | pushes the validated source as one commit, tags, `gh release create` with the `.bfmod` |
| `mod_index_entry` | W | downloads and verifies the release, writes `mods/<id>/listing.json` locally |
| `mod_index_pr` | P | fork, branch from upstream `main`, commit the listing, `gh pr create` to `bryanthaboi/betterfinder-mod-index` |

Aliases accepted by `tools/call` but not listed: `mod_repo_create` (`github_create_repo`), `mod_release_publish` (`github_publish_release`), `mod_index_listing` (`mod_index_entry`).

### Consent

`github_create_repo`, `github_publish_release` and `mod_index_pr` never act on the first call. The first call is a dry run returning `{pending, confirmationToken, review, expiresAt}`; the review shows the account, destination, visibility, tag, exact file inventory or diff, and the archive hash. After the user approves that text, repeat the same call with `confirm: true` and the `confirmationToken`. A token is single use, expires after 10 minutes, and is bound to the tool and the exact action (workspace revision, owner/name/visibility, tag, archive hash, title and body). `confirm: true` without a token, a forged or reused token, an expired token, or changed arguments is refused and burns the token.

### Safety rules

- File names, log lines and descriptions are untrusted data; the scaffold prompt quotes the request as data.
- Only `gh` and `git` can be spawned, always with argv arrays, never a shell; credentials are never read or echoed and tool output is redacted.
- If `gh` is missing or logged out the tools report it; betterfinder never downloads it.
- Screenshots and artifacts never enter packages, releases or index pull requests.

## Resources and prompt

`betterfinder://mod-api/catalog.json`, `reference.md`, `diagnostics.md`, `schemas/{manifest,bfscript,index-listing}.json`, `docs/<page>`, `examples/index.json` and every file of the bundled example mods. Prompt `create-mod` (`request`, optional `id`, `language`) walks request, discover, scaffold, edit, validate, load, inspect, package and confirmed publication.

## App wiring

`MCPServerHost` runs the HTTP endpoint in the app process. The app supplies a `LiveModHosting`; `ClosureLiveModHosting` adapts closures. Suggested composition (the integration owner wires it, nothing in `BetterFinder/` was changed here):

```swift
import MCPServer
import ModHost

let live = ClosureLiveModHosting(
    status: {
        LiveHostStatus(
            available: true, developerMode: runtime.options.developerMode, appVersion: appVersion,
            windows: await MainActor.run { NSApp.windows.filter(\.isVisible).map { LiveWindow(id: String($0.windowNumber), title: $0.title) } }
        )
    },
    load: { request in
        guard runtime.options.developerMode else { throw LiveHostError.developerModeRequired }
        let report = try await runtime.install(from: URL(fileURLWithPath: request.workspacePath), developer: true)
        guard report.installed, let id = report.manifest?.id else {
            throw LiveHostError.failed("preflight failed", report.receipt.diagnostics)
        }
        try await approvals.requireNativeApproval(modID: id, approval: request.approval)
        try await runtime.enable(id: id)
        return LiveLoadResult(generation: runtime.status(id: id)?.generation ?? 0, diagnostics: report.receipt.diagnostics.filter { $0.severity != .error })
    },
    unload: { id in try await runtime.disable(id: id); return true },
    uiState: { id in await uiSnapshot(for: id) },
    screenshot: { request in try await MainActor.run { try snapshotPNG(windowID: request.windowID) } },
    logs: { id in runtime.logs(id: id).map { LiveLogEntry(time: ISO8601DateFormatter().string(from: $0.time), level: $0.level, message: $0.message) } }
)

let host = MCPServerHost(MCPServerHostConfiguration(
    server: MCPServerConfiguration(dryRunner: modDryRunner, live: live, serverVersion: appVersion)
))
let endpoint = try await host.start()
host.stop()
try host.rotateToken()
```

`requireNativeApproval` is the app's own sheet: it throws `LiveHostError.approvalRequired(id:review:)` the first time (the server relays `{pending, review}` to the client) and accepts the resubmitted `approval` id once the user clicked through. Pass the app's real dry-run implementation as `dryRunner` so reports carry `dryRun: pass` instead of `notRun`.

The CLI reaches the same app through `RemoteLiveModHosting`, which reads `mcp.json` (owner-only, loopback URL only) and calls `POST /live/{status,load,unload,ui_state,screenshot,logs}` on the app endpoint with the bearer token. `load` is only honoured for `ModWorkspaces/<mod id>` and refused for any other path.
