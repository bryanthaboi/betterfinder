# betterfinder-mod CLI

```text
betterfinder-mod 1.0.0

usage: betterfinder-mod <command> [options]

commands:
  validate <path> [--json] [--strict] [--host-version x.y.z] [--api-version x.y.z] [--listing listing.json [--authors file|dir]]
      Run the shared preflight on a mod folder or .bfmod archive. Exits 1 when any error is reported;
      --strict also exits 1 when a required check did not run (for example the dry run).
      --listing also checks an index listing against the archive: manifest identity and permissions, archive
      size and sha256, and the author's Ed25519 signature using the key file from --authors (default: the
      index's authors/<author>.json next to the listing).
  scaffold <id> [--language bfscript|ts|js] [--template column|sidebar|toolbar|panel|preview|command|theme] [--out dir]
      Create a mod that passes validate. Defaults: --language bfscript, --template command, --out ./<id>.
      sidebar and theme are data-only and ignore --language.
  package <path> --out <file.bfmod>
      Validate, then write a reproducible archive, its sha256 and <file>.receipt.json.
  docs --out <dir>
      Write the wiki pages (API, manifest, diagnostics, CLI, getting started) and betterfinder.d.ts.
  dts [--out betterfinder.d.ts]
      Write the editor declarations for the virtual betterfinder module (stdout without --out).
  index-entry <path> --repo <github url> --release-url <url> [--commit sha] [--tag tag] [--key-id id]
              [--signature base64 | --author-key file] [--summary text] [--categories UI,THEME,...] [--tags a,b] [--out file|dir]
      Generate the mod index listing.json for a release (stdout without --out; a directory gets listing.json).
      --author-key signs the release with a raw or base64 Ed25519 private key file.
  mcp [--stdio | --http] [--port n] [--token-file path] [--workspaces dir] [--allow-origin url] [--no-live]
      Run the MCP authoring server (stdio by default; --http listens on 127.0.0.1 behind a bearer token file).
  version [--json]
      Print tool, validator, API and toolchain versions.
  help
      Show this text.
```
