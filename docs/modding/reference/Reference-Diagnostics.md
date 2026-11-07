# Diagnostic codes

Every diagnostic carries a stable `BF####` code, a severity, a package-relative file, optional `line:column` or JSON pointer, a message and usually a fix. Any `error` blocks enablement.

| Code | Severity | Meaning |
|---|---|---|
| `BF1001` | error | Invalid JSON |
| `BF1002` | error | Unknown key in closed object |
| `BF1003` | error | Missing required key |
| `BF1004` | error | Wrong JSON type |
| `BF1005` | error | Invalid value |
| `BF1006` | error | Unsupported manifest version |
| `BF1007` | error | Invalid mod id |
| `BF1008` | error | Invalid semantic version or range |
| `BF1009` | error | Size bound exceeded |
| `BF1010` | error | JSON Schema violation |
| `BF1011` | error | Duplicate id |
| `BF1012` | error | Reserved id namespace |
| `BF1013` | error | Mod id is not namespaced by its author |
| `BF2001` | error | Unknown script construct |
| `BF2002` | error | Malformed script program |
| `BF2003` | error | Unsupported script format version |
| `BF2004` | error | Invalid identifier |
| `BF2005` | error | Literal out of range |
| `BF2010` | error | Unknown hook signature |
| `BF2011` | error | Unsupported hook signature version |
| `BF2012` | error | Unknown function |
| `BF2013` | error | Wrong number of arguments |
| `BF2014` | error | Type mismatch |
| `BF2015` | error | Unknown variable |
| `BF2016` | error | Duplicate or shadowing variable |
| `BF2017` | error | Unknown record field |
| `BF2018` | error | Async call not awaited |
| `BF2019` | error | Missing return on some path |
| `BF2020` | error | Loop without a valid bound |
| `BF2021` | error | Loop bound exceeds limit |
| `BF2022` | error | Recursive call |
| `BF2023` | error | Call depth exceeded |
| `BF2024` | error | Script size or nesting limit exceeded |
| `BF2026` | error | Optional value used without unwrap |
| `BF2028` | error | Unknown type |
| `BF2029` | error | Value is not a list |
| `BF2030` | error | Reserved name |
| `BF2031` | error | Assignment to a read-only variable |
| `BF3001` | warning | Unreachable code |
| `BF3002` | warning | Unused variable |
| `BF3003` | warning | Loop without cancellation check |
| `BF3004` | warning | Unused function |
| `BF4001` | error | Required grant not declared |
| `BF4002` | warning | Declared grant never used |
| `BF4003` | warning | Duplicate grant |
| `BF4004` | error | Local or private network destination needs allowPrivate |
| `BF4005` | warning | Plain HTTP endpoint |
| `BF4006` | warning | Unrestricted process execution |
| `BF4007` | error | Unknown broker operation |
| `BF4008` | error | Invalid grant shape |
| `BF4009` | warning | Secret-like setting should use credentials |
| `BF4010` | error | Root id not declared by any grant |
| `BF5001` | error | Forbidden file type in package |
| `BF5002` | error | Package has no manifest.json |
| `BF5003` | error | Path escapes the package |
| `BF5004` | error | Referenced path does not exist |
| `BF5005` | error | Duplicate or case-colliding path |
| `BF5006` | error | Package too large |
| `BF5010` | error | data/1 mods must not declare an entry |
| `BF5011` | error | Entry missing or wrong extension for runtime |
| `BF5012` | error | data/1 mods cannot declare handlers or hooks |
| `BF5020` | error | Mod depends on itself |
| `BF5021` | error | Dependency listed as conflict |
| `BF5022` | error | Dependency cycle |
| `BF5023` | error | Conflicting mods installed together |
| `BF5024` | error | Dependency missing or hash mismatch |
| `BF5030` | error | Archive entry path escapes the package |
| `BF5031` | error | Archive entry is a symbolic link |
| `BF5032` | error | Archive entry is a device, socket or FIFO |
| `BF5033` | error | Archive entry has an executable permission bit |
| `BF5034` | error | Archive expansion ratio exceeds limit |
| `BF5035` | error | Archive or entry size cap exceeded |
| `BF5036` | error | Archive contains a duplicate entry |
| `BF5037` | error | Archive entry is encrypted |
| `BF5038` | error | Archive uses unsupported ZIP64 structures |
| `BF5039` | error | Archive entry name disagrees between headers |
| `BF6001` | error | API range excludes host API |
| `BF6002` | error | App range excludes host app |
| `BF6003` | warning | Version range has no upper bound |
| `BF7001` | error | Unknown reference |
| `BF7002` | error | Handler function not found in script |
| `BF7003` | error | Handler is not bound to the right hook |
| `BF7004` | warning | Hook handler never referenced |
| `BF7005` | error | Unknown hook |
| `BF7006` | error | Unsupported hook version |
| `BF7007` | error | Duplicate hook |
| `BF7008` | error | Duplicate keybinding |
| `BF7009` | warning | Keybinding without command/control/option modifier |
| `BF7010` | error | Index listing does not match manifest |
| `BF7011` | error | Release signature does not verify |
| `BF7012` | error | Release key is not a trusted key of the author |
| `BF7013` | error | Release artifact does not match the listing |
| `BF8001` | error | TypeScript type error |
| `BF8002` | error | TypeScript syntax error |
| `BF8003` | error | Script violates the sandbox policy |
| `BF8004` | error | Catalog accessed dynamically |
| `BF8005` | error | Dry run failed |
| `BF8006` | error | Dry run timed out |
| `BF8007` | error | Script host crashed during dry run |
| `BF9001` | error | Internal validator disagreement |
| `BF9002` | info | Check not run |

## TypeScript and JavaScript mapping

TypeScript compiler errors are reported with the nearest catalog code and the compiler's own number at the start of the message (`TS2322: ...`). Script policy violations use `policy 9000x`.

| Compiler code | Reported as | Typical cause |
|---|---|---|
| TS1005 | `BF2002` Malformed script program | syntax error |
| TS2304 | `BF2015` Unknown variable | unknown identifier |
| TS2305 | `BF7001` Unknown reference | unknown import from betterfinder |
| TS2322 | `BF2014` Type mismatch | wrong value type |
| TS2339 | `BF2012` Unknown function | unknown catalog function |
| TS2339 | `BF2017` Unknown record field | unknown record field |
| TS2345 | `BF2014` Type mismatch | wrong argument type |
| TS2554 | `BF2013` Wrong number of arguments | wrong argument count |
| TS2366 | `BF2019` Missing return on some path | missing return |
| TS18048 | `BF2026` Optional value used without unwrap | optional value used without a check |
| TS2540 | `BF2031` Assignment to a read-only variable | assignment to const |
| policy 90001 | `BF5001` Forbidden file type in package | invalid script file name |
| policy 90002 | `BF2001` Unknown script construct | forbidden construct |
| policy 90003 | `BF5003` Path escapes the package | escaping or bare import |
| policy 90004 | `BF7002` Handler function not found in script | missing handler export |

Everything else reports as `BF2014`. Catalog use the validator cannot follow (a namespace passed around as a value or accessed with a computed key) is `BF2001` because grants could not be checked.
