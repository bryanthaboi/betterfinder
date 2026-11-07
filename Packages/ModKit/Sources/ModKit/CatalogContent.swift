import Foundation

private func mkFn(
    _ name: String, _ summary: String, _ params: [ModParam], _ returns: ModTypeExpr,
    requires: [GrantRequirement] = [], deadline: Int = 2000, cancellable: Bool = true,
    failure: ModFailurePolicy = .reject, errors: [String] = [], gesture: Bool = false, batch: Int? = nil
) -> ModFunction {
    ModFunction(
        name: name, summary: summary, params: params, returns: returns, requires: requires,
        deadlineMs: deadline, cancellable: cancellable, failure: failure,
        errors: errors, gesture: gesture, batchLimit: batch
    )
}

private func mkHook(
    _ name: String, _ summary: String, input: ModTypeExpr, output: ModTypeExpr = .void,
    requires: [GrantRequirement] = [], deadline: Int, cancellable: Bool = true,
    failure: ModFailurePolicy, multiple: Bool = false, contribution: String? = nil
) -> ModHookSignature {
    ModHookSignature(
        name: name, version: 1, summary: summary, input: input, output: output, requires: requires,
        deadlineMs: deadline, cancellable: cancellable, failure: failure, multiple: multiple, contribution: contribution
    )
}

private func mkP(_ n: String, _ t: ModTypeExpr, optional: Bool = false, _ doc: String = "") -> ModParam {
    ModParam(n, t, optional: optional, doc: doc)
}

private func mkF(_ n: String, _ t: ModTypeExpr, optional: Bool = false, _ doc: String = "") -> ModField {
    ModField(n, t, optional: optional, doc: doc)
}

private let handleDoc = "Opaque mod-scoped handle; valid only for the invocation or grant that produced it."

public extension ModCatalog {
    static let v1: ModCatalog = {
        let types: [ModTypeDef] = [
            .alias("Int64String", "Decimal-string encoding of a 64-bit integer (sizes, offsets).", .string),
            .enumeration("FileKind", "Kind of a file system item.", ["file", "folder", "symlink", "other"]),
            .enumeration("Appearance", "Effective window appearance.", ["light", "dark"]),
            .enumeration("ActivateReason", "Why activate runs.", ["startup", "enable", "reload", "update"]),
            .enumeration("DeactivateReason", "Why deactivate runs.", ["disable", "uninstall", "reload", "update", "shutdown"]),
            .enumeration("LogLevel", "Log severity.", ["debug", "info", "warn", "error"]),
            .enumeration("NotifyLevel", "Notification severity.", ["info", "warning", "error"]),
            .enumeration("FileOpOrigin", "What initiated a file operation.", ["user", "undo", "retry", "mod", "automation"]),
            .enumeration("FileOpStatus", "Committed per-item outcome.", ["succeeded", "failed", "skipped", "cancelled"]),
            .enumeration("FileOperation", "A guarded file operation.", FileOperationName.allCases.map(\.rawValue)),
            .enumeration("Decision", "Before-hook verdict.", ["allow", "deny"]),
            .enumeration("SortOrder", "Directory listing order.", ["name", "modifiedDescending", "sizeDescending"]),
            .enumeration("ConflictPolicy", "Name conflict resolution.", ["fail", "rename", "skip"]),
            .enumeration("ArchiveFormat", "Archive container format.", ["zip", "tarGz"]),
            .enumeration("OperationState", "Queued operation state.", ["queued", "running", "done", "failed", "cancelled"]),
            .enumeration("UINodeType", "Native control a UINode maps to.", ["vstack", "hstack", "text", "markdown", "button", "list", "progress", "divider", "textField"]),
            .enumeration("GitState", "Git working tree state of a path.", ["modified", "added", "deleted", "renamed", "untracked", "conflicted"]),
            .enumeration("HttpMethod", "HTTP method.", HTTPMethod.allCases.map(\.rawValue)),

            .record("HookContext", "First argument of every hook.", [
                mkF("modId", .string), mkF("generation", .integer, "Registration generation; late replies are rejected."),
                mkF("locale", .string), mkF("appearance", .ref("Appearance")), mkF("deadlineMs", .integer, "Remaining time budget."),
            ]),
            .record("FileRef", "Reference to a file. Optional fields are populated only when granted.", [
                mkF("handle", .string, handleDoc), mkF("name", .string), mkF("kind", .ref("FileKind")),
                mkF("path", .string, optional: true, "Requires ui.selection level paths or a root grant."),
                mkF("size", .ref("Int64String"), optional: true, "Requires metadata access."),
                mkF("modified", .string, optional: true, "ISO-8601; requires metadata access."),
            ]),
            .record("DirectoryPage", "One page of directory entries.", [mkF("entries", .list(.ref("FileRef"))), mkF("cursor", .string, optional: true)]),
            .record("BytesChunk", "A ranged read.", [mkF("base64", .string), mkF("eof", .boolean)]),
            .record("ColumnValue", "One cell value, keyed by item handle.", [
                mkF("handle", .string), mkF("text", .string, optional: true), mkF("number", .number, optional: true),
                mkF("sortKey", .string, optional: true),
                mkF("label", .string, optional: true),
            ]),
            .record("ImageInfo", "Image header facts.", [
                mkF("handle", .string), mkF("width", .integer), mkF("height", .integer), mkF("format", .string, optional: true),
            ]),
            .record("LocationRef", "A browsable location.", [
                mkF("id", .string), mkF("title", .string), mkF("provider", .string, optional: true),
                mkF("folder", .ref("FileRef"), optional: true, "The folder shown, from locations.current only. Its access follows the mod's grants: fs.write destination during a user gesture, otherwise fs.read/fs.write selection; with neither it is a reference only."),
            ]),
            .record("UIListItem", "Row of a list node.", [mkF("id", .string), mkF("title", .string), mkF("subtitle", .string, optional: true)]),
            .record("UINode", "Data-only description of a native control tree.", [
                mkF("type", .ref("UINodeType")), mkF("id", .string, optional: true), mkF("text", .string, optional: true),
                mkF("label", .string, optional: true, "Accessibility label."),
                mkF("command", .string, optional: true, "Command run on press; for a textField, run on Return with args {id, value, fields}. Buttons receive args {fields} with the panel's current text field values."),
                mkF("placeholder", .string, optional: true, "Placeholder of a textField; text is its initial value."),
                mkF("value", .number, optional: true), mkF("children", .list(.ref("UINode")), optional: true),
                mkF("items", .list(.ref("UIListItem")), optional: true),
            ]),
            .record("ActivateInput", "activate input.", [mkF("reason", .ref("ActivateReason")), mkF("previousVersion", .string, optional: true)]),
            .record("DeactivateInput", "deactivate input.", [mkF("reason", .ref("DeactivateReason"))]),
            .record("SelectionChangedInput", "selection.changed input.", [mkF("revision", .integer), mkF("count", .integer), mkF("items", .list(.ref("FileRef")))]),
            .record("LocationChangedInput", "location.changed input.", [mkF("revision", .integer), mkF("location", .ref("LocationRef"))]),
            .record("ThemeChangedInput", "theme.changed input.", [mkF("name", .string), mkF("appearance", .ref("Appearance"))]),
            .record("SettingsChangedInput", "settings.changed input.", [mkF("changed", .list(.string)), mkF("values", .json)]),
            .record("CommandRunInput", "command.run input.", [
                mkF("commandId", .string), mkF("selection", .list(.ref("FileRef"))), mkF("args", .json, optional: true),
            ]),
            .record("CommandResult", "command.run result; message is shown as a toast.", [mkF("message", .string, optional: true), mkF("operationId", .string, optional: true)]),
            .record("ColumnValuesInput", "column.values input; at most 128 items per call.", [
                mkF("column", .string), mkF("items", .list(.ref("FileRef"))), mkF("revision", .integer),
            ]),
            .record("SearchQueryInput", "search.query input.", [
                mkF("provider", .string), mkF("query", .string), mkF("limit", .integer), mkF("cursor", .string, optional: true),
                mkF("scope", .ref("FileRef"), optional: true),
            ]),
            .record("SearchResult", "One search hit.", [
                mkF("id", .string), mkF("title", .string), mkF("subtitle", .string, optional: true), mkF("handle", .string, optional: true),
            ]),
            .record("SearchBatch", "A page of search results.", [mkF("results", .list(.ref("SearchResult"))), mkF("done", .boolean), mkF("cursor", .string, optional: true)]),
            .record("PreviewRenderInput", "preview.render input.", [
                mkF("provider", .string), mkF("item", .ref("FileRef")), mkF("maxBytes", .integer), mkF("appearance", .ref("Appearance")),
            ]),
            .record("PreviewResult", "preview.render result.", [mkF("title", .string, optional: true), mkF("node", .ref("UINode"))]),
            .record("LocationListInput", "location.list input.", [
                mkF("location", .string), mkF("path", .string, "Virtual path; empty for the root."), mkF("limit", .integer),
                mkF("cursor", .string, optional: true),
            ]),
            .record("ResourceEntry", "Entry of a provided location.", [
                mkF("id", .string), mkF("name", .string), mkF("kind", .ref("FileKind")),
                mkF("size", .ref("Int64String"), optional: true), mkF("modified", .string, optional: true),
            ]),
            .record("LocationPage", "location.list result.", [mkF("items", .list(.ref("ResourceEntry"))), mkF("cursor", .string, optional: true)]),
            .record("FileOpItem", "One item of an operation.", [
                mkF("itemId", .string), mkF("source", .ref("FileRef")), mkF("destinationName", .string, optional: true),
            ]),
            .record("FileOpBeforeInput", "fileop.before.* input.", [
                mkF("operationId", .string), mkF("attemptId", .string), mkF("origin", .ref("FileOpOrigin")),
                mkF("operation", .ref("FileOperation")), mkF("items", .list(.ref("FileOpItem"))),
            ]),
            .record("OperationDecision", "fileop.before.* result.", [mkF("decision", .ref("Decision")), mkF("reason", .string, optional: true)]),
            .record("FileOpOutcome", "Committed outcome for one item.", [
                mkF("itemId", .string), mkF("source", .ref("FileRef")), mkF("status", .ref("FileOpStatus")), mkF("error", .string, optional: true),
            ]),
            .record("FileOpAfterInput", "fileop.after.* input.", [
                mkF("operationId", .string), mkF("attemptId", .string), mkF("origin", .ref("FileOpOrigin")),
                mkF("operation", .ref("FileOperation")), mkF("partial", .boolean), mkF("outcomes", .list(.ref("FileOpOutcome"))),
            ]),
            .record("OperationTicket", "Queued operation identity.", [mkF("operationId", .string)]),
            .record("OperationStatus", "Progress of a queued operation.", [
                mkF("operationId", .string), mkF("state", .ref("OperationState")), mkF("completed", .integer), mkF("total", .integer),
            ]),
            .record("HttpHeader", "One HTTP header.", [mkF("name", .string), mkF("value", .string)]),
            .record("NetRequest", "Outgoing request; must match a granted endpoint.", [
                mkF("url", .string), mkF("method", .ref("HttpMethod")), mkF("headers", .list(.ref("HttpHeader")), optional: true),
                mkF("body", .string, optional: true), mkF("timeoutMs", .integer, optional: true),
                mkF("credential", .string, optional: true, "Credential handle from credentials.request."),
            ]),
            .record("NetResponse", "Incoming response; bodies are capped by the grant.", [
                mkF("status", .integer), mkF("headers", .list(.ref("HttpHeader"))), mkF("body", .string),
            ]),
            .record("CredentialHandle", "Opaque destination-bound Keychain credential.", [mkF("handle", .string), mkF("destination", .string)]),
            .record("CredentialInfo", "Credential metadata without secret material.", [mkF("name", .string), mkF("destination", .string)]),
            .record("GitStatusEntry", "One changed path.", [mkF("path", .string), mkF("state", .ref("GitState"))]),
            .record("GitStatus", "Curated git status result.", [mkF("branch", .string, optional: true), mkF("entries", .list(.ref("GitStatusEntry")))]),
            .record("ProcessResult", "Result of an unrestricted process.", [
                mkF("exitCode", .integer), mkF("stdout", .string), mkF("stderr", .string),
            ]),
        ]

        let selectionOrRoot = GrantRequirement.fsRead(["selection", "root"])

        let functions: [ModFunction] = [
            mkFn("ui.setPanel", "Replace the content of a declared panel.", [mkP("panelId", .string), mkP("node", .ref("UINode"))], .void,
               requires: [.ui(.panel)], deadline: 1000, errors: ["notFound", "limitExceeded"]),
            mkFn("ui.setStatusText", "Set the text of a declared status bar item.", [mkP("itemId", .string), mkP("text", .string)], .void,
               requires: [.ui(.statusBar)], deadline: 1000, errors: ["notFound"]),
            mkFn("ui.setToolbarItemState", "Enable/disable or retitle a declared toolbar item.",
               [mkP("itemId", .string), mkP("enabled", .boolean), mkP("title", .string, optional: true)], .void,
               requires: [.ui(.toolbar)], deadline: 1000, errors: ["notFound"]),
            mkFn("ui.notify", "Show a rate-limited toast.", [mkP("message", .string), mkP("level", .ref("NotifyLevel"))], .void, deadline: 1000, errors: ["limitExceeded"]),
            mkFn("ui.pickDestination", "Native folder picker; resolves to null when cancelled. Requires a user gesture.",
               [mkP("prompt", .string)], .optional(.ref("FileRef")),
               requires: [GrantRequirement.fsWrite(["destination"])], deadline: 120_000, errors: ["noGesture"], gesture: true),

            mkFn("commands.run", "Run one of this mod's own commands.", [mkP("commandId", .string), mkP("args", .json, optional: true)], .optional(.ref("CommandResult")),
               deadline: 10_000, errors: ["notFound", "recursionLimit"]),
            mkFn("commands.setEnabled", "Enable or disable one of this mod's own commands.", [mkP("commandId", .string), mkP("enabled", .boolean)], .void,
               deadline: 1000, errors: ["notFound"]),

            mkFn("fs.root", "Resolve a user-picked root bound at grant time; null when unbound.", [mkP("rootId", .string)], .optional(.ref("FileRef")),
               requires: [.fsRead(["root"])], deadline: 1000, errors: ["notGranted"]),
            mkFn("fs.stat", "Stat an item; size and modified are filled in.", [mkP("item", .ref("FileRef"))], .ref("FileRef"),
               requires: [selectionOrRoot], errors: ["notFound", "notGranted", "staleHandle"]),
            mkFn("fs.list", "List one directory level.", [mkP("directory", .ref("FileRef")), mkP("limit", .integer), mkP("order", .ref("SortOrder")), mkP("cursor", .string, optional: true)], .ref("DirectoryPage"),
               requires: [selectionOrRoot], errors: ["notFound", "notGranted", "staleHandle", "limitExceeded"], batch: 128),
            mkFn("fs.walk", "Recursively list below a root; bounded depth and count.",
               [mkP("directory", .ref("FileRef")), mkP("maxDepth", .integer), mkP("limit", .integer), mkP("cursor", .string, optional: true)], .ref("DirectoryPage"),
               requires: [.fsRead(["root"], recursive: true)], deadline: 5000, errors: ["notFound", "notGranted", "staleHandle", "limitExceeded"], batch: 128),
            mkFn("fs.readText", "Read a UTF-8 text file up to maxBytes (truncated, never an error).", [mkP("item", .ref("FileRef")), mkP("maxBytes", .integer)], .string,
               requires: [selectionOrRoot], errors: ["notFound", "notGranted", "staleHandle", "notText"]),
            mkFn("fs.readBytes", "Ranged binary read; offset is a decimal string.", [mkP("item", .ref("FileRef")), mkP("offset", .ref("Int64String")), mkP("length", .integer)], .ref("BytesChunk"),
               requires: [selectionOrRoot], errors: ["notFound", "notGranted", "staleHandle", "limitExceeded"]),
            mkFn("fs.writeText", "Create a text file in a directory handle.",
               [mkP("directory", .ref("FileRef")), mkP("name", .string), mkP("text", .string), mkP("conflict", .ref("ConflictPolicy"))], .ref("FileRef"),
               requires: [.fsWrite()], errors: ["notFound", "notGranted", "exists", "invalidName"]),
            mkFn("fs.mkdir", "Create a directory in a directory handle.", [mkP("directory", .ref("FileRef")), mkP("name", .string)], .ref("FileRef"),
               requires: [.fsWrite()], errors: ["notFound", "notGranted", "exists", "invalidName"]),

            mkFn("operations.copy", "Queue a copy through the file operation queue.",
               [mkP("items", .list(.ref("FileRef"))), mkP("destination", .ref("FileRef")), mkP("conflict", .ref("ConflictPolicy"))], .ref("OperationTicket"),
               requires: [selectionOrRoot, .fsWrite(["destination", "root"])], deadline: 2000, errors: ["notGranted", "limitExceeded"], gesture: true, batch: 128),
            mkFn("operations.move", "Queue a move through the file operation queue.",
               [mkP("items", .list(.ref("FileRef"))), mkP("destination", .ref("FileRef")), mkP("conflict", .ref("ConflictPolicy"))], .ref("OperationTicket"),
               requires: [selectionOrRoot, .fsWrite(["destination", "root"])], deadline: 2000, errors: ["notGranted", "limitExceeded", "denied"], gesture: true, batch: 128),
            mkFn("operations.trash", "Queue a move to Trash.", [mkP("items", .list(.ref("FileRef")))], .ref("OperationTicket"),
               requires: [.fsWrite(["selection", "root"])], deadline: 2000, errors: ["notGranted", "limitExceeded", "denied"], gesture: true, batch: 128),
            mkFn("operations.rename", "Queue a rename.", [mkP("item", .ref("FileRef")), mkP("newName", .string)], .ref("OperationTicket"),
               requires: [.fsWrite(["selection", "root"])], deadline: 2000, errors: ["notGranted", "invalidName", "limitExceeded", "denied"], gesture: true),
            mkFn("operations.status", "Progress of an operation this mod queued.", [mkP("operationId", .string)], .ref("OperationStatus"),
               deadline: 1000, errors: ["notFound"]),
            mkFn("operations.cancel", "Cancel an operation this mod queued; false when already finished.", [mkP("operationId", .string)], .boolean,
               deadline: 1000, errors: ["notFound"]),

            mkFn("search.files", "Query the host file index below a root.",
               [mkP("query", .string), mkP("root", .ref("FileRef")), mkP("limit", .integer), mkP("cursor", .string, optional: true)], .ref("SearchBatch"),
               requires: [.fsRead(["root"])], deadline: 5000, errors: ["notGranted", "staleHandle", "limitExceeded"], batch: 128),

            mkFn("locations.open", "Navigate the front window to one of this mod's provided locations.", [mkP("location", .string), mkP("path", .string)], .void,
               requires: [.ui(.location)], deadline: 1000, errors: ["notFound"]),
            mkFn("locations.refresh", "Invalidate a provided location's listing.", [mkP("location", .string)], .void,
               requires: [.ui(.location)], deadline: 1000, errors: ["notFound"]),
            mkFn("locations.current", "The location shown in the front window, with a FileRef for its folder when it is a local folder.", [], .ref("LocationRef"), deadline: 1000),

            mkFn("preview.refresh", "Re-render the preview for an item.", [mkP("provider", .string), mkP("item", .ref("FileRef"))], .void,
               requires: [.ui(.preview)], deadline: 1000, errors: ["notFound"]),
            mkFn("preview.invalidate", "Drop cached previews of a provider.", [mkP("provider", .string)], .void,
               requires: [.ui(.preview)], deadline: 1000, errors: ["notFound"]),

            mkFn("media.imageDimensions", "Pixel dimensions of images as display cells; non-images yield an empty cell.", [mkP("items", .list(.ref("FileRef")))], .list(.ref("ColumnValue")),
               requires: [selectionOrRoot], errors: ["notGranted", "staleHandle", "limitExceeded"], batch: 128),
            mkFn("media.imageInfo", "Image header facts.", [mkP("items", .list(.ref("FileRef")))], .list(.ref("ImageInfo")),
               requires: [selectionOrRoot], errors: ["notGranted", "staleHandle", "limitExceeded"], batch: 128),

            mkFn("net.fetch", "HTTP(S) request to a granted endpoint; redirects and DNS are rechecked.", [mkP("request", .ref("NetRequest"))], .ref("NetResponse"),
               requires: [GrantRequirement(.net)], deadline: 15_000, errors: ["notGranted", "denied", "timeout", "limitExceeded", "network"]),

            mkFn("process.archive.create", "Create an archive of items through the queued archive broker operation.",
               [mkP("items", .list(.ref("FileRef"))), mkP("destination", .ref("FileRef")), mkP("name", .string), mkP("format", .ref("ArchiveFormat"))], .ref("OperationTicket"),
               requires: [selectionOrRoot, .fsWrite(["destination", "root"]), .broker("archive.create")], deadline: 2000,
               errors: ["notGranted", "limitExceeded", "exists", "invalidName"], gesture: true, batch: 128),
            mkFn("process.git.status", "Curated git status for a root; no arbitrary git arguments.", [mkP("root", .ref("FileRef"))], .ref("GitStatus"),
               requires: [.fsRead(["root"]), .broker("git.status")], deadline: 5000, errors: ["notGranted", "notARepository", "timeout"]),
            mkFn("process.run", "Run an arbitrary executable with the full authority of the user account (high trust).",
               [mkP("executable", .string), mkP("args", .list(.string)), mkP("cwd", .ref("FileRef"), optional: true)], .ref("ProcessResult"),
               requires: [GrantRequirement(.processExec, mode: .unrestricted)], deadline: 30_000, errors: ["notGranted", "noGesture", "timeout", "spawnFailed"], gesture: true),

            mkFn("settings.get", "Read one of this mod's settings.", [mkP("key", .string)], .json, deadline: 250, errors: ["notFound"]),
            mkFn("settings.getAll", "Read all of this mod's settings.", [], .json, deadline: 250),
            mkFn("settings.set", "Write a setting; validated against the manifest schema.", [mkP("key", .string), mkP("value", .json)], .void,
               deadline: 1000, errors: ["notFound", "invalidValue"]),

            mkFn("storage.get", "Read private storage; null when absent.", [mkP("key", .string)], .json,
               requires: [GrantRequirement(.storage)], deadline: 1000, errors: ["notGranted"]),
            mkFn("storage.set", "Write private storage within the quota.", [mkP("key", .string), mkP("value", .json)], .void,
               requires: [GrantRequirement(.storage)], deadline: 1000, errors: ["notGranted", "quotaExceeded"]),
            mkFn("storage.delete", "Delete a private storage key.", [mkP("key", .string)], .void,
               requires: [GrantRequirement(.storage)], deadline: 1000, errors: ["notGranted"]),
            mkFn("storage.keys", "List private storage keys.", [], .list(.string),
               requires: [GrantRequirement(.storage)], deadline: 1000, errors: ["notGranted"]),

            mkFn("credentials.list", "Credential metadata for granted destinations.", [], .list(.ref("CredentialInfo")),
               requires: [GrantRequirement(.credentials)], deadline: 1000, errors: ["notGranted"]),
            mkFn("credentials.request", "Ask the user (native prompt) for a credential bound to a destination; null when declined.",
               [mkP("name", .string), mkP("destination", .string)], .optional(.ref("CredentialHandle")),
               requires: [GrantRequirement(.credentials)], deadline: 120_000, errors: ["notGranted", "denied"], gesture: true),

            mkFn("events.supports", "Whether the host implements a function or hook version; availability, not authorization.",
               [mkP("name", .string), mkP("version", .integer)], .boolean, deadline: 250, cancellable: false),
            mkFn("events.delay", "Suspend the handler for a bounded time (max 10000 ms).", [mkP("ms", .integer)], .void,
               deadline: 10_500, errors: ["limitExceeded"]),

            mkFn("log.write", "Append a rate-limited, redacted log entry.", [mkP("level", .ref("LogLevel")), mkP("message", .string), mkP("fields", .json, optional: true)], .void,
               deadline: 250, cancellable: false, failure: .ignore),
        ]

        let intercept = { (op: FileOperationName) in [GrantRequirement(.operationsIntercept, fileOperation: op)] }
        let observe = { (op: FileOperationName) in [GrantRequirement(.operationsObserve, fileOperation: op)] }
        var hooks: [ModHookSignature] = [
            mkHook("activate", "Mod enabled or reloaded; register dynamic state here.", input: .ref("ActivateInput"), deadline: 2000, cancellable: false, failure: .reject),
            mkHook("deactivate", "Mod is being disabled; release resources.", input: .ref("DeactivateInput"), deadline: 1000, cancellable: false, failure: .ignore),
            mkHook("selection.changed", "Passive selection notification.", input: .ref("SelectionChangedInput"),
                 requires: [GrantRequirement(.uiSelection)], deadline: 250, failure: .ignore),
            mkHook("location.changed", "The front window navigated.", input: .ref("LocationChangedInput"), deadline: 250, failure: .ignore),
            mkHook("theme.changed", "Theme or appearance changed.", input: .ref("ThemeChangedInput"), deadline: 250, failure: .ignore),
            mkHook("settings.changed", "A setting of this mod changed.", input: .ref("SettingsChangedInput"), deadline: 250, failure: .ignore),
            mkHook("command.run", "Run a contributed command.", input: .ref("CommandRunInput"), output: .ref("CommandResult"),
                 deadline: 10_000, failure: .reject, multiple: true, contribution: "commands"),
            mkHook("column.values", "Cell values for visible items; batched, cached by identity/revision.", input: .ref("ColumnValuesInput"),
                 output: .list(.ref("ColumnValue")), deadline: 2000, failure: .degrade, multiple: true, contribution: "columns"),
            mkHook("search.query", "Provide search results.", input: .ref("SearchQueryInput"), output: .ref("SearchBatch"),
                 deadline: 5000, failure: .degrade, multiple: true, contribution: "searchProviders"),
            mkHook("preview.render", "Render a preview as a native node tree.", input: .ref("PreviewRenderInput"), output: .ref("PreviewResult"),
                 deadline: 2000, failure: .degrade, multiple: true, contribution: "previews"),
            mkHook("location.list", "List a provided location.", input: .ref("LocationListInput"), output: .ref("LocationPage"),
                 deadline: 5000, failure: .degrade, multiple: true, contribution: "locations"),
        ]
        for op in FileOperationName.allCases {
            hooks.append(mkHook("fileop.before.\(op.rawValue)", "Veto a \(op.rawValue) before it starts; allow or deny only.", input: .ref("FileOpBeforeInput"),
                              output: .ref("OperationDecision"), requires: intercept(op), deadline: 1000, failure: .pause))
        }
        for op in FileOperationName.allCases {
            hooks.append(mkHook("fileop.after.\(op.rawValue)", "Committed per-item outcomes of a \(op.rawValue); no veto or retry authority.", input: .ref("FileOpAfterInput"),
                              requires: observe(op), deadline: 2000, failure: .ignore))
        }

        let namespaces: [ModNamespaceDoc] = [
            .init(name: "ui", summary: "Panels, status text, toolbar state, toasts and native pickers."),
            .init(name: "commands", summary: "Run and toggle this mod's own commands."),
            .init(name: "fs", summary: "Granted, handle-based file access."),
            .init(name: "operations", summary: "Queued copy/move/trash/rename through the shared file operation queue."),
            .init(name: "search", summary: "Host index queries."),
            .init(name: "locations", summary: "Provided (virtual) locations."),
            .init(name: "preview", summary: "Preview refresh and invalidation."),
            .init(name: "media", summary: "Host media helpers."),
            .init(name: "net", summary: "Granted network access."),
            .init(name: "process", summary: "Curated broker operations and the high-trust unrestricted escape hatch."),
            .init(name: "settings", summary: "This mod's own settings."),
            .init(name: "storage", summary: "Private key/value storage."),
            .init(name: "credentials", summary: "Opaque, destination-bound Keychain credentials."),
            .init(name: "events", summary: "Capability probing and bounded delays."),
            .init(name: "log", summary: "Logging."),
        ]

        let contributions: [ModContributionDoc] = ModContributionKind.allCases.map { kind in
            let summary: String
            switch kind {
            case .toolbar: summary = "Toolbar buttons that run a command."
            case .sidebarSections: summary = "Sidebar sections of known folders or provided locations."
            case .contextMenu: summary = "Context menu items for items or the folder background."
            case .columns: summary = "List columns computed by a column.values handler."
            case .statusBar: summary = "Status bar items whose text is set via ui.setStatusText."
            case .panels: summary = "Docked or slide-out panels filled via ui.setPanel."
            case .previews: summary = "Previewers for file extensions rendered by preview.render."
            case .views: summary = "Alternative browse layouts using this mod's columns."
            case .locations: summary = "Virtual locations listed by location.list."
            case .commands: summary = "Commands run by command.run."
            case .keybindings: summary = "Key chords bound to commands."
            case .settingsPanes: summary = "Settings panes rendered from this mod's settings schema."
            case .themes: summary = "Theme JSON files from the package."
            case .iconSets: summary = "Icon set directories from the package."
            case .sounds: summary = "Sound set directories from the package."
            case .searchProviders: summary = "Search providers backed by search.query."
            }
            return ModContributionDoc(key: kind.rawValue, surface: kind.surface, hook: kind.hookName, summary: summary)
        }

        let permissions: [ModPermissionDoc] = ModPermissionKind.allCases.map {
            let spec = $0.fieldSpec
            return ModPermissionDoc(kind: $0, required: spec.required, optional: spec.optional, summary: $0.summary)
        }

        let brokers: [ModBrokerOperation] = [
            .init(name: "archive.create", function: "process.archive.create", summary: "Queued archive creation (zip, tar.gz) of granted items into a granted destination."),
            .init(name: "git.status", function: "process.git.status", summary: "Read-only git status for a granted root."),
        ]

        let diagnostics = ModDiagnosticCode.allCases.map {
            ModDiagnosticDoc(code: $0.rawValue, severity: $0.defaultSeverity, title: $0.title)
        }

        return ModCatalog(
            catalogVersion: ModKitVersion.api, manifestVersion: ModKitVersion.manifestVersion,
            scriptFormat: ModKitVersion.scriptFormat, toolchain: ModKitVersion.toolchain, limits: .v1,
            namespaces: namespaces, types: types, functions: functions, hooks: hooks, permissions: permissions,
            contributions: contributions, brokerOperations: brokers, diagnostics: diagnostics
        )
    }()
}
