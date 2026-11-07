# Using the MCP server

The built-in MCP surface lets a client discover the installed catalog, scaffold a workspace, edit contained files, validate, and request a native test session. Read the [MCPServer README](../../Packages/MCPServer/README.md) for the full tool list, flags and consent rules.

## Connect a client

The app embeds the CLI, so there is nothing to build. Two transports are available.

**Stdio.** The client launches the embedded `betterfinder-mod` itself. Use the absolute path inside the app bundle:

```json
{
  "mcpServers": {
    "betterfinder-mod": {
      "command": "/Applications/betterfinder.app/Contents/MacOS/betterfinder-mod",
      "args": ["mcp"]
    }
  }
}
```

The stdio server reaches the running app through `~/Library/Application Support/betterfinder/mcp.json`. Add `--no-live` to disable live tools.

**HTTP.** Choose **Mods → Start MCP Server** in the app, then **Mods → Copy MCP Config**. The clipboard gets a ready-made config containing both servers, with the HTTP one filled in:

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

`PORT` and `TOKEN` are random and change when the app restarts or the token rotates, so copy the config again after a restart. The server listens on `127.0.0.1` only, and every request must carry the bearer token. (**Copy MCP Config** also starts the server if it isn't running.)

Treat the copied config as a secret: paste it into your client's config file, not into a prompt or a command line. The stdio server's stdout is protocol-only; logs go to stderr.

Ask the client to discover `mod_api`, scaffold with `mod_scaffold`, read/write only the paired authoring workspace, and validate the exact revision before a load request. Loading and screenshots require native approval. Inspect UI state, own-mod logs and the approved app-window screenshot; do not capture the desktop or unrelated windows.

Package only after inspecting the receipt and the intended visible behavior. Repository creation, release uploads and index PRs require explicit review of the exact external action. Client statements such as `confirmed:true` cannot replace native approval. Tool availability and argument schemas must come from the server, not this illustrative workflow.

See [getting started](getting-started.md), [publishing](publishing.md) and [permissions](permissions.md).
