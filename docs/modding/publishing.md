# Publishing to the mod index

Keep source, assets and license in your own repository. The [index repository](https://github.com/bryanthaboi/betterfinder-mod-index) contains metadata only. Nothing in this guide publishes automatically.

## Author signing

Every release is signed with an Ed25519 key you own. The app refuses releases that are unsigned, signed with a key the index doesn't list for you, or whose archive doesn't match the listing.

1. Generate an Ed25519 key pair. Keep the private key (raw or base64 file) outside your mod and out of git.
2. Add `authors/<author>.json` to the index in a PR:

```json
{
  "author": "alice",
  "keys": [
    {
      "keyId": "alice:2026-11",
      "publicKey": "BASE64_PUBLIC_KEY",
      "validFrom": "2026-11-01T00:00:00Z",
      "validUntil": "2028-01-01T00:00:00Z"
    }
  ]
}
```

`keyId` must start with `<author>:`. A first author key needs maintainer review; key changes need old-key endorsement or another review.

The signature covers the canonical JSON `{api,app,id,sha256,version}` for the release (`api` and `app` are the compatibility ranges, `sha256` is the archive hash). `index-entry` builds and signs it for you.

## Release steps

1. Validate and check the dry run: `betterfinder-mod validate ./my-mod`. Review permissions and asset provenance. Keep editor files and build output out of the archive.
2. Package: `betterfinder-mod package ./my-mod --out /tmp/my-mod.bfmod`.
3. Tag the reviewed commit in your repository and upload the exact `.bfmod` bytes as a release asset.
4. Generate the listing and sign it:

```sh
betterfinder-mod index-entry /tmp/my-mod.bfmod \
  --repo https://github.com/OWNER/REPO \
  --release-url https://github.com/OWNER/REPO/releases/download/v1.0.0/my-mod.bfmod \
  --tag v1.0.0 --commit FULL_40_CHARACTER_COMMIT \
  --key-id alice:2026-11 --author-key ~/keys/alice.key \
  --categories WORKFLOW --out mods/alice.my-mod
```

`--out` can be a file or a directory (a directory gets `listing.json`). Use `--signature BASE64` instead of `--author-key` if you sign elsewhere; without either the listing carries a placeholder signature and will fail.

5. Check the listing against the archive before submitting:

```sh
betterfinder-mod validate /tmp/my-mod.bfmod --listing mods/alice.my-mod/listing.json --authors ../betterfinder-mod-index/authors
```

This checks manifest identity and permissions, archive size and SHA-256, and the signature. `--authors` takes a key file or a directory; by default the CLI looks for `authors/<author>.json` next to the listing. Failures are `BF7010` (listing doesn't match the package), `BF7011` (bad signature), `BF7012` (key not trusted for that author) and `BF7013` (archive doesn't match the listing).

6. Submit a PR with `mods/<author>.<name>/listing.json` (and your `authors/<author>.json` the first time) plus optional icon and screenshots. Explain every permission, the license, and the exact release, hash and key. Don't submit generated feed or signature edits.

Signing establishes who published a release, not that it is safe. Maintainers still verify artifact bytes, author identity and full preflight before promotion.

See [permissions](permissions.md), [CLI reference](reference/Reference-CLI.md) and the index's [contribution instructions](https://github.com/bryanthaboi/betterfinder-mod-index/blob/main/CONTRIBUTING.md). The [real world examples](index.md#real-world-examples) all went through this flow.
