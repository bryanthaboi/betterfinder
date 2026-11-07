# Troubleshooting

Start with `betterfinder-mod validate <path> --json`. Read the first error's file, JSON pointer or line/column, message and fix. Fix root errors before following secondary type failures. The [complete diagnostic catalog](reference/Reference-Diagnostics.md) defines every stable code.

| Codes | Fix |
| --- | --- |
| `BF1001`–`BF1013` | Correct JSON, closed-object field names, required fields, author-prefixed ID and semantic-version ranges. Compare the generated manifest reference. |
| `BF2001`–`BF2031` | Correct script syntax/signatures/types. Await async calls; check optionals; return on every branch; bound loops; remove recursion and forbidden constructs. |
| `BF3001`–`BF3004` | Remove unreachable/unused code and add loop cancellation checks. |
| `BF4001`, `BF4010` | Declare the exact missing grant or rootId; choose an appropriate scope rather than widening every grant. |
| `BF4002`, `BF4003` | Remove unused or duplicate grants. |
| `BF4004`, `BF4005` | Prefer public HTTPS endpoints; explicitly justify any necessary private-network access. |
| `BF4006` | High-trust unrestricted execution warning. Prefer a curated broker; otherwise review full account authority before approval. |
| `BF4007`, `BF4008` | Use catalog broker operation names and the fields allowed for that permission kind. |
| `BF4009` | Move secret material out of settings into destination-bound credential handles. |
| `BF5001`–`BF5006` | Remove forbidden files, symlinks, escaping/case-colliding paths; add missing assets/manifest; reduce package size. |
| `BF5030`–`BF5039` | The `.bfmod` archive itself is unsafe or malformed: escaping paths, symlinks, devices, executable bits, zip bombs, oversize or duplicate entries, encryption, ZIP64, mismatched entry names. Repackage with `betterfinder-mod package`. |
| `BF5010`–`BF5012` | Data-only packages have no entry/handlers. Script packages need a matching runtime and entry extension. |
| `BF5020`–`BF5024` | Resolve dependency cycles, missing hashes, conflicts and self-dependencies. |
| `BF6001`–`BF6003` | Match host API/app versions and add a supported upper compatibility bound. |
| `BF7001`–`BF7009` | Fix IDs, command references, entry exports, hook versions/bindings and duplicate key chords. |
| `BF7010` | Make listing identity, version, compatibility, permissions and release metadata match the exact package. |
| `BF7011` | The release signature doesn't verify. Re-sign the canonical `{api,app,id,sha256,version}` payload with the key named in `release.keyId`. |
| `BF7012` | The key isn't listed for that author (or is outside its validity dates). Add or rotate it in `authors/<author>.json`. |
| `BF7013` | The archive's size or SHA-256 doesn't match the listing. Regenerate the listing from the exact uploaded archive. |
| `BF8001`, `BF8002` | Fix TypeScript type/syntax errors using the compiler message. |
| `BF8003`, `BF8004` | Remove sandbox-policy violations and computed/dynamic catalog access. |
| `BF8005`–`BF8007` | The dry run failed (usually a `tests/*.bftest.json` mismatch, the message shows expected vs got), timed out or crashed the script host. Fix the handler or the test and rerun `validate`. |
| `BF9001` | Preserve the failing package and version report; report validator disagreement to the maintainer. |
| `BF9002` | A check did not run. Use the real host dry-run path before enabling; do not suppress the incomplete check. |

TS messages include the original compiler number (for example `TS2322`). Policy `90001`–`90004` maps into package, forbidden-construct, containment and missing-export diagnostics. Use direct catalog calls so the validator can analyze permissions.

## Static pass but cannot enable

Inspect `checks` and the receipt's `ok`, not only the exit code. The dry run now really runs, so `dryRun=fail` is an error. A `BF9002` note means the check host wasn't available; `--strict` rejects that incomplete receipt. The app requires a passing preflight and native grant approval.

## Missing content or stale reload

Rebind a root if `fs.root` returns null. Handles can expire; request current invocation data instead of persisting handles. Confirm the contribution is wired by the app and has a matching surface grant. Failed reloads keep the previous generation; inspect diagnostics and logs before retrying. Watchdog failures can quarantine a mod or enter safe mode. Disable the failing mod, then restore a known-good snapshot through host management.

## Publication cannot complete

Run `betterfinder-mod validate <archive> --listing <listing.json> --authors <index>/authors` and fix the `BF7010`–`BF7013` errors it reports. The app applies the same checks on install and rejects unsigned or mismatched releases. Don't bypass them or use a placeholder signature.
