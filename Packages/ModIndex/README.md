# ModIndex integration

`ModIndexProviding.fetch()` returns Settings `ModIndexSnapshot`. Use one shared
`ModIndexClient` instance per source. `isOffline` marks a stale network fallback;
`isExpired` disables installation through Settings. Only connectivity failures use
fallback; signature, expiry and rollback failures remain errors. Cached signatures
are verified again before every use. ETags apply to the feed, never the signature.

For install, call `verifiedListing(id:)` to obtain a currently verified, unexpired
ModKit listing, then `ModArtifactDownloader.download`. This method checks bounded
bytes and the artifact SHA-256 only. ModHost must still verify author-key binding,
author release signature, manifest consistency and full preflight before install.
No method activates a mod or grants permissions.

Token providers are async closures and tokens aren't persisted. Private GitHub
API asset endpoints can be supplied separately using `url` and `signatureURL`;
GitHub API requests get the octet-stream Accept header. Redirects must stay HTTPS
and cross-host redirects lose Authorization. Supply the actual app/API versions
when constructing the client. No readme/icon payload is fetched or rendered.

TrustedIndexKey.pinned contains the production public key. The private key lives at ~/.config/betterfinder-index/signing.key on the owner's mac.
Replace it before production. Multiple keys with explicit validity windows permit
an app-mediated overlap; feeds cannot authorize new keys. Revocation requires an
app update. Deleting both application state and cache resets rollback history;
ordinary cache eviction does not. Local administrator tampering is outside this
protection. Watermark and cache writes fail closed after interrupted persistence.

Author keys live in the index repo as `authors/<author>.json` (`{author, keys:[{keyId, publicKey, validFrom, validUntil}]}`, Ed25519, base64). `build` requires an author file for every listing, checks each release signature, and embeds the author files in the signed feed. `verifiedRelease(id:)` returns the listing with its author keys only when the release signature verifies; `ModArtifactDownloader.download(_: ModVerifiedRelease)` also checks size and SHA-256. Feeds without `authors` still decode.

`mod-index-tool validate-artifacts <submission> <betterfinder-mod> <changed.txt> [<trusted index>]` runs `betterfinder-mod validate <archive> --listing <listing.json> --authors <file> --strict` for every changed listing under a network-denied sandbox. Author keys come from the trusted (base) index when it knows the author; a new author file is used but flagged for maintainer review. AppBridge's `ModIndexBridge` already serves verified releases to ModHost.
