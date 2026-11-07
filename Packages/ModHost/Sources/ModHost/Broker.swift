import Darwin
import FileOps
import Foundation
import ImageIO
import Integration
import ModHostProtocol
import ModKit
import Settings

protocol ModCallHandling: AnyObject, Sendable {
    func handle(_ call: ModCallRequest, invocation: ModInvocation) async -> ModCallOutcome
}

protocol ModBrokerRuntime: AnyObject, Sendable {
    func runNestedCommand(_ commandId: String, args: JSONValue?, parent: ModInvocation) async -> ModCallOutcome
    func applyUI(_ update: ModUIUpdate) async
    func settingsChanged(_ mod: ActiveMod, keys: [String]) async
}

struct ModBrokerDependencies: Sendable {
    var catalog: ModCatalog
    var grants: ModGrantStore
    var services: ModHostServices
    var fileOperations: ModFileOperationsPerforming?
    var fileSearch: ModFileSearching?
    var credentials: ModCredentialStoring?
    var net: ModNetBroker
    var ledger: ModOperationLedger
}

final class ModBroker: ModCallHandling, @unchecked Sendable {
    let deps: ModBrokerDependencies
    let validator: ModValueValidator
    weak var runtime: ModBrokerRuntime?
    var archiveRunner: @Sendable ([String], ModProcessHandle) async -> ModProcessResult? = { args, handle in
        await ModProcessRunner.run("/usr/bin/tar", args, environment: ModProcessRunner.baseEnvironment, timeout: 600, maxOutput: 16 * 1024, handle: handle)
    }
    var scopedAccess: ScopedAccessAuthorizing { deps.grants.scopedAccess }

    init(deps: ModBrokerDependencies) {
        self.deps = deps
        self.validator = ModValueValidator(catalog: deps.catalog)
    }

    func handle(_ call: ModCallRequest, invocation: ModInvocation) async -> ModCallOutcome {
        let mod = invocation.mod
        guard call.modId == mod.id, call.generation == mod.generation else { return .failure(.denied("call identity does not match the invocation")) }
        guard let fn = deps.catalog.function(named: call.name) else { return .failure(.notFound("unknown catalog function '\(call.name)'")) }
        if let v = validator.validateArguments(call.args, for: fn) { return .failure(.invalid(v.description)) }
        let grants = mod.grants
        for r in fn.requires where !grants.satisfies(r) {
            return .failure(.notGranted("\(call.name) requires grant \(r.summary)"))
        }
        if fn.gesture, !invocation.gesture { return .failure(ModCallError("noGesture", "\(call.name) requires a user gesture")) }
        var args = call.args
        while args.count < fn.params.count { args.append(.null) }
        do {
            let result = try await dispatch(fn, args, invocation)
            if let v = validator.validate(result, fn.returns) {
                mod.logs.append("error", "host returned an invalid \(fn.name) result: \(v)", rateLimited: false)
                return .failure(.internalError("host produced an invalid result"))
            }
            return .value(result)
        } catch let e as ModCallError {
            return .failure(e)
        } catch {
            return .failure(.internalError(error.localizedDescription))
        }
    }

    func dispatch(_ fn: ModFunction, _ a: [JSONValue], _ inv: ModInvocation) async throws -> JSONValue {
        let mod = inv.mod
        switch fn.name {
        case "ui.setPanel":
            let id = try declared(mod, a[0], mod.manifest.contributes.panels.map(\.id), "panel")
            guard let node = ModUINode.from(a[1], owner: mod.id) else { throw ModCallError.limit("panel node is invalid or too large") }
            await runtime?.applyUI(.panelContent(panel: id, node: node))
            return .null
        case "ui.setStatusText":
            let id = try declared(mod, a[0], mod.manifest.contributes.statusBar.map(\.id), "status bar item")
            await runtime?.applyUI(.statusText(item: id, text: String((a[1].stringValue ?? "").prefix(256))))
            return .null
        case "ui.setToolbarItemState":
            let id = try declared(mod, a[0], mod.manifest.contributes.toolbar.map(\.id), "toolbar item")
            await runtime?.applyUI(.toolbarItemState(item: id, enabled: a[1].boolValue ?? true, title: a[2].stringValue.map { String($0.prefix(128)) }))
            return .null
        case "ui.notify":
            guard mod.allowNotify() else { throw ModCallError.limit("too many notifications") }
            await runtime?.applyUI(.notify(modId: mod.id, message: String((a[0].stringValue ?? "").prefix(512)), level: a[1].stringValue ?? "info"))
            return .null
        case "ui.pickDestination":
            guard let url = await deps.services.pickDestination(modId: mod.id, prompt: String((a[0].stringValue ?? "").prefix(256))) else { return .null }
            guard let real = ModPathRules.realpath(url.path) else { return .null }
            let token = scopedAccess.issueSelectionToken(modID: mod.id, urls: [URL(fileURLWithPath: real)], mode: .readWrite, lifetime: ScopedAccessAuthorizer.maxTokenLifetime)
            inv.track(token.id)
            return try ref(mod, path: real, scope: .destination(token: token.id, base: real), includePath: false, includeMeta: false)
        case "commands.run":
            let id = a[0].stringValue ?? ""
            guard mod.manifest.contributes.commands.contains(where: { $0.id == id }) else { throw ModCallError.notFound("unknown command '\(id)'") }
            guard inv.depth < 3 else { throw ModCallError("recursionLimit", "commands.run nesting limit reached") }
            guard let runtime else { throw ModCallError.internalError("runtime unavailable") }
            let outcome = await runtime.runNestedCommand(id, args: a[1].isNull ? nil : a[1], parent: inv)
            switch outcome {
            case .value(let v): return v
            case .failure(let e): throw e
            }
        case "commands.setEnabled":
            let id = a[0].stringValue ?? ""
            let cid = try declared(mod, a[0], mod.manifest.contributes.commands.map(\.id), "command")
            mod.setCommandEnabled(id, a[1].boolValue ?? true)
            await runtime?.applyUI(.commandEnabled(command: cid, enabled: a[1].boolValue ?? true))
            return .null
        case "fs.root": return try fsRoot(mod, a[0].stringValue ?? "")
        case "fs.stat":
            let item = try resolve(mod, a[0], need: .read)
            return try ref(mod, path: item.path, scope: item.entry.scope, includePath: includePath(mod, item.entry.scope), includeMeta: true)
        case "fs.list": return try fsList(mod, a)
        case "fs.walk": return try fsWalk(mod, a)
        case "fs.readText": return try fsReadText(mod, a)
        case "fs.readBytes": return try fsReadBytes(mod, a)
        case "fs.writeText": return try fsCreate(mod, a, directory: false)
        case "fs.mkdir": return try fsCreate(mod, a, directory: true)
        case "operations.copy", "operations.move": return try await opsTransfer(mod, a, move: fn.name == "operations.move")
        case "operations.trash":
            guard let ops = deps.fileOperations else { throw ModCallError.denied("file operations are unavailable") }
            let items = try list(a[0], max: 128).map { try resolve(mod, $0, need: .write) }
            return try await trackExternal(mod, ops) { try await ops.trash(items.map { URL(fileURLWithPath: $0.real) }, modId: mod.id) }
        case "operations.rename":
            guard let ops = deps.fileOperations else { throw ModCallError.denied("file operations are unavailable") }
            let item = try resolve(mod, a[0], need: .write)
            let name = a[1].stringValue ?? ""
            guard ModPathRules.validName(name) else { throw ModCallError("invalidName", "'\(name)' is not a valid file name") }
            return try await trackExternal(mod, ops) { try await ops.rename(URL(fileURLWithPath: item.real), to: name, modId: mod.id) }
        case "operations.status":
            let id = a[0].stringValue ?? ""
            let p: ModOperationProgress
            switch await deps.ledger.lookup(id, owner: mod.id, external: deps.fileOperations) {
            case .progress(let found): p = found
            case .expired: throw ModCallError.notFound("operation \(id) has expired")
            case .unknown: throw ModCallError.notFound("unknown operation")
            }
            return .object(["operationId": .string(id), "state": .string(p.state.rawValue), "completed": .int(p.completed), "total": .int(p.total)])
        case "operations.cancel":
            let id = a[0].stringValue ?? ""
            guard let r = await deps.ledger.cancel(id, owner: mod.id, external: deps.fileOperations) else { throw ModCallError.notFound("unknown operation") }
            return .bool(r)
        case "search.files": return try await searchFiles(mod, a)
        case "locations.open":
            let id = try declared(mod, a[0], mod.manifest.contributes.locations.map(\.id), "location")
            await runtime?.applyUI(.openLocation(location: id, path: String((a[1].stringValue ?? "").prefix(1024))))
            return .null
        case "locations.refresh":
            let id = try declared(mod, a[0], mod.manifest.contributes.locations.map(\.id), "location")
            await runtime?.applyUI(.refreshLocation(location: id))
            return .null
        case "locations.current":
            let env = await deps.services.environment()
            var o: [String: JSONValue] = ["id": .string(env.currentLocation?.id ?? ""), "title": .string(env.currentLocation?.title ?? "")]
            if let p = env.currentLocation?.provider { o["provider"] = .string(p) }
            if let folder = env.currentFolder, let ref = currentFolderRef(mod, folder, invocation: inv) { o["folder"] = ref }
            return .object(o)
        case "preview.refresh":
            let id = try declared(mod, a[0], mod.manifest.contributes.previews.map(\.id), "preview")
            let item = try resolve(mod, a[1], need: .read)
            await runtime?.applyUI(.refreshPreview(provider: id, item: URL(fileURLWithPath: item.path)))
            return .null
        case "preview.invalidate":
            let id = try declared(mod, a[0], mod.manifest.contributes.previews.map(\.id), "preview")
            await runtime?.applyUI(.invalidatePreviews(provider: id))
            return .null
        case "media.imageDimensions", "media.imageInfo": return try media(mod, a, info: fn.name == "media.imageInfo")
        case "net.fetch": return try await deps.net.fetch(mod, a[0], credentials: deps.credentials)
        case "process.archive.create": return try archive(mod, a)
        case "process.git.status": return try await gitStatus(mod, a)
        case "process.run": return try await processRun(mod, a)
        case "settings.get":
            let key = a[0].stringValue ?? ""
            guard let s = mod.settings, let field = s.schema.field(key), !field.isSecret, let v = s.value(for: key) else { throw ModCallError.notFound("unknown setting '\(key)'") }
            return Self.json(v)
        case "settings.getAll":
            guard let s = mod.settings else { return .object([:]) }
            return .object(s.values.mapValues(Self.json))
        case "settings.set":
            let key = a[0].stringValue ?? ""
            guard let s = mod.settings, let field = s.schema.field(key), !field.isSecret else { throw ModCallError.notFound("unknown setting '\(key)'") }
            guard let value = Self.settingValue(a[1], field.kind) else { throw ModCallError("invalidValue", "wrong type for '\(key)'") }
            do { _ = try s.set(value, for: key) } catch { throw ModCallError("invalidValue", error.localizedDescription) }
            let runtime = runtime
            Task { await runtime?.settingsChanged(mod, keys: [key]) }
            return .null
        case "storage.get": return mod.storage.get(try storageKey(a[0]))
        case "storage.set":
            try mod.storage.set(try storageKey(a[0]), a[1], quota: mod.storageQuota)
            return .null
        case "storage.delete":
            try mod.storage.set(try storageKey(a[0]), nil, quota: Int.max)
            return .null
        case "storage.keys": return .array(mod.storage.keys().map(JSONValue.string))
        case "credentials.list":
            let allowed = Set(mod.grants.filter { $0.kind == .credentials }.flatMap { $0.destinations ?? [] })
            let items = (deps.credentials?.names(modId: mod.id) ?? []).filter { allowed.contains($0.destination) }
            return .array(items.map { .object(["name": .string($0.name), "destination": .string($0.destination)]) })
        case "credentials.request":
            let name = a[0].stringValue ?? "", dest = (a[1].stringValue ?? "").lowercased()
            let allowed = Set(mod.grants.filter { $0.kind == .credentials }.flatMap { $0.destinations ?? [] })
            guard allowed.contains(dest) else { throw ModCallError.notGranted("destination '\(dest)' is not granted") }
            guard ModPatterns.matches(name, ModPatterns.settingKey), let store = deps.credentials else { throw ModCallError.invalid("invalid credential name") }
            guard let secret = await deps.services.requestCredential(modId: mod.id, name: name, destination: dest) else { return .null }
            try store.store(modId: mod.id, name: name, destination: dest, secret: secret)
            return .object(["handle": .string("cred:\(name)"), "destination": .string(dest)])
        case "events.supports":
            let name = a[0].stringValue ?? "", version = a[1].intValue ?? 1
            return .bool(deps.catalog.function(named: name) != nil && version == 1 || deps.catalog.hook(named: name, version: version) != nil)
        case "events.delay":
            let ms = a[0].intValue ?? 0
            guard (0...10_000).contains(ms) else { throw ModCallError.limit("delay must be 0...10000 ms") }
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return .null
        case "log.write":
            let level = a[0].stringValue ?? "info"
            var message = a[1].stringValue ?? ""
            if !a[2].isNull { message += " " + String(a[2].canonicalString().prefix(1024)) }
            mod.logs.append(level, message)
            return .null
        default:
            throw ModCallError.notFound("\(fn.name) is not implemented by this host")
        }
    }

    func currentFolderRef(_ mod: ActiveMod, _ folder: URL, invocation inv: ModInvocation) -> JSONValue? {
        guard let real = ModPathRules.realpath(folder.path), let id = ModFileIdentity.lstat(real), id.isDirectory else { return nil }
        let grants = mod.grants
        let url = URL(fileURLWithPath: real)
        if inv.gesture, grants.contains(where: { $0.kind == .fsWrite && $0.scope == .destination }) {
            let token = scopedAccess.issueSelectionToken(modID: mod.id, urls: [url], mode: .readWrite, lifetime: ScopedAccessAuthorizer.maxTokenLifetime)
            inv.track(token.id)
            return try? ref(mod, path: real, scope: .destination(token: token.id, base: real), includePath: includePath(mod, .reference), includeMeta: false)
        }
        let read = grants.fs(.fsRead, scope: .selection)
        let write = grants.fs(.fsWrite, scope: .selection)
        if !read.isEmpty || !write.isEmpty {
            let token = scopedAccess.issueSelectionToken(modID: mod.id, urls: [url], mode: write.isEmpty ? .read : .readWrite, lifetime: ScopedAccessAuthorizer.maxTokenLifetime)
            inv.track(token.id)
            return try? ref(mod, path: real, scope: .selection(token: token.id, recursive: read.contains { $0.recursive == true }, base: real),
                            includePath: includePath(mod, .reference), includeMeta: grants.selectionLevel == .metadata)
        }
        return try? ref(mod, path: real, scope: .reference, includePath: includePath(mod, .reference), includeMeta: false)
    }

    func declared(_ mod: ActiveMod, _ v: JSONValue, _ ids: [String], _ what: String) throws -> ModContributionID {
        let id = v.stringValue ?? ""
        guard ids.contains(id) else { throw ModCallError.notFound("unknown \(what) '\(id)'") }
        return ModContributionID(modId: mod.id, localId: id)
    }

    func storageKey(_ v: JSONValue) throws -> String {
        guard let k = v.stringValue, !k.isEmpty, k.utf8.count <= 256 else { throw ModCallError.invalid("storage keys are 1...256 bytes") }
        return k
    }

    func list(_ v: JSONValue, max: Int) throws -> [JSONValue] {
        guard let l = v.arrayValue else { throw ModCallError.invalid("expected a list") }
        guard l.count <= max else { throw ModCallError.limit("at most \(max) items per call") }
        return l
    }

    static func json(_ v: ModSettingValue) -> JSONValue {
        switch v {
        case .bool(let b): return .bool(b)
        case .integer(let i): return .int(i)
        case .number(let d): return .double(d)
        case .string(let s): return .string(s)
        }
    }

    static func settingValue(_ v: JSONValue, _ kind: ModSettingsSchema.Kind) -> ModSettingValue? {
        switch kind {
        case .boolean: return v.boolValue.map(ModSettingValue.bool)
        case .integer: return v.intValue.map(ModSettingValue.integer)
        case .number: return v.numberValue.map(ModSettingValue.number)
        case .string, .enumeration: return v.stringValue.map(ModSettingValue.string)
        case .secret: return nil
        }
    }

    func includePath(_ mod: ActiveMod, _ scope: ModHandleScope) -> Bool {
        if case .root = scope { return true }
        let level = mod.grants.selectionLevel
        return level == .paths || level == .metadata
    }

    func ref(_ mod: ActiveMod, path: String, scope: ModHandleScope, includePath: Bool, includeMeta: Bool) throws -> JSONValue {
        guard let id = ModFileIdentity.lstat(path) else { throw ModCallError.notFound("item no longer exists") }
        guard let handle = mod.handles.mint(path: path, scope: scope, generation: mod.generation) else { throw ModCallError.notFound("item no longer exists") }
        var o: [String: JSONValue] = ["handle": .string(handle), "name": .string((path as NSString).lastPathComponent), "kind": .string(id.kind)]
        if includePath { o["path"] = .string(path) }
        if includeMeta {
            o["size"] = .string(String(id.size))
            o["modified"] = .string(ISO8601DateFormatter().string(from: id.modified))
        }
        return .object(o)
    }

    func makeRefs(_ mod: ActiveMod, urls: [URL], invocation: ModInvocation?) -> [JSONValue] {
        let grants = mod.grants
        let read = grants.fs(.fsRead, scope: .selection)
        let write = grants.fs(.fsWrite, scope: .selection)
        let recursive = read.contains { $0.recursive == true }
        let level = grants.selectionLevel
        let resolved = urls.map { ModPathRules.realpath($0.path) }
        let paths = resolved.compactMap { $0 }
        var token: UUID?
        if !read.isEmpty || !write.isEmpty, !paths.isEmpty {
            let t = scopedAccess.issueSelectionToken(modID: mod.id, urls: paths.map { URL(fileURLWithPath: $0) }, mode: write.isEmpty ? .read : .readWrite, lifetime: ScopedAccessAuthorizer.maxTokenLifetime)
            invocation?.track(t.id)
            token = t.id
        }
        return zip(urls, resolved).map { url, real in
            let fallback = JSONValue.object(["handle": .string("gone_" + UUID().uuidString), "name": .string(url.lastPathComponent), "kind": .string("other")])
            guard let p = real else { return fallback }
            let scope: ModHandleScope = token.map { .selection(token: $0, recursive: recursive, base: p) } ?? .reference
            return (try? ref(mod, path: p, scope: scope, includePath: level == .paths || level == .metadata, includeMeta: level == .metadata)) ?? fallback
        }
    }

    func resolve(_ mod: ActiveMod, _ refValue: JSONValue, need: ModAccessNeed) throws -> ModResolvedItem {
        guard let handle = refValue["handle"]?.stringValue else { throw ModCallError.invalid("expected a FileRef") }
        guard let entry = mod.handles.lookup(handle, generation: mod.generation) else { throw ModCallError.stale() }
        guard let identity = ModFileIdentity.lstat(entry.path), identity.device == entry.device, identity.inode == entry.inode else {
            throw ModCallError.stale("the item changed since the handle was issued")
        }
        guard let real = ModPathRules.realpath(entry.path) else { throw ModCallError.notFound("item no longer exists") }
        let grants = mod.grants
        let writing = need == .write
        let mode: ScopedAccessMode = writing ? .readWrite : .read
        func authorize(_ token: UUID?) throws {
            guard scopedAccess.authorize(URL(fileURLWithPath: real), mode: mode, modID: mod.id, token: token).isAllowed else {
                throw ModCallError.notGranted("access to this item is not granted")
            }
        }
        switch entry.scope {
        case .reference:
            throw ModCallError.notGranted("this mod has no file access grant for the item")
        case .selection(let token, let recursive, let base):
            let kind: ModPermissionKind = writing ? .fsWrite : .fsRead
            let perms = grants.fs(kind, scope: .selection)
            guard !perms.isEmpty else { throw ModCallError.notGranted("\(kind.rawValue) with scope selection is not granted") }
            let isBase = real == base
            if !isBase || need == .list || need == .walk {
                guard recursive, perms.contains(where: { $0.recursive == true }) else {
                    throw ModCallError.notGranted("selecting a folder does not grant access to its contents")
                }
                guard ModPathRules.contains(base, real) else { throw ModCallError.notGranted("item escapes the selection") }
            }
            try authorize(token)
        case .root(let rootId, let path):
            let kind: ModPermissionKind = writing ? .fsWrite : .fsRead
            let perms = grants.filter { $0.kind == kind && $0.scope == .root && $0.rootId == rootId }
            guard !perms.isEmpty else { throw ModCallError.notGranted("\(kind.rawValue) for root '\(rootId)' is not granted") }
            if need == .walk, !perms.contains(where: { $0.recursive == true }) { throw ModCallError.notGranted("root '\(rootId)' is not granted recursively") }
            guard let bound = deps.grants.boundRoot(mod.id, rootId: rootId), let boundReal = ModPathRules.realpath(bound.path), boundReal == path else {
                throw ModCallError.stale("root '\(rootId)' was unbound")
            }
            guard ModPathRules.contains(boundReal, real) else { throw ModCallError.notGranted("item escapes root '\(rootId)'") }
            try authorize(nil)
        case .destination(let token, let base):
            guard grants.contains(where: { $0.kind == .fsWrite && $0.scope == .destination }) else { throw ModCallError.notGranted("fs.write with scope destination is not granted") }
            guard ModPathRules.contains(base, real) else { throw ModCallError.notGranted("item escapes the destination") }
            try authorize(token)
        }
        if need == .list || need == .walk {
            guard let rid = ModFileIdentity.lstat(real), rid.isDirectory else { throw ModCallError.invalid("not a directory") }
        }
        return ModResolvedItem(path: entry.path, real: real, identity: identity, entry: entry)
    }

    func verifyDescriptor(_ fd: Int32, _ item: ModResolvedItem) throws {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { throw ModCallError.notFound("cannot verify the opened item") }
        let opened = String(cString: buf)
        let base: String
        switch item.entry.scope {
        case .selection(_, let recursive, let b): base = recursive ? b : item.real
        case .root(_, let p): base = p
        case .destination(_, let b): base = b
        case .reference: throw ModCallError.notGranted("not granted")
        }
        guard ModPathRules.contains(base, opened) else { throw ModCallError.notGranted("opened item escapes its scope") }
    }

    func fsRoot(_ mod: ActiveMod, _ rootId: String) throws -> JSONValue {
        guard mod.grants.contains(where: { ($0.kind == .fsRead || $0.kind == .fsWrite) && $0.scope == .root && $0.rootId == rootId }) else {
            throw ModCallError.notGranted("root '\(rootId)' is not granted")
        }
        guard let root = deps.grants.boundRoot(mod.id, rootId: rootId), let real = ModPathRules.realpath(root.path) else { return .null }
        return try ref(mod, path: real, scope: .root(rootId: rootId, path: real), includePath: true, includeMeta: false)
    }

    func children(_ mod: ActiveMod, _ dir: ModResolvedItem) throws -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.real) else { throw ModCallError.notFound("cannot list the folder") }
        return names.filter { $0 != ".DS_Store" }
    }

    func childScope(_ scope: ModHandleScope) -> ModHandleScope { scope }

    func pageArgs(_ limit: JSONValue, _ cursor: JSONValue) throws -> (limit: Int, offset: Int) {
        let l = limit.intValue ?? 0
        guard (1...deps.catalog.limits.batchItems).contains(l) else { throw ModCallError.limit("limit must be 1...\(deps.catalog.limits.batchItems)") }
        let offset = cursor.stringValue.flatMap(Int.init) ?? 0
        guard offset >= 0 else { throw ModCallError.invalid("invalid cursor") }
        return (l, offset)
    }

    func fsList(_ mod: ActiveMod, _ a: [JSONValue]) throws -> JSONValue {
        let dir = try resolve(mod, a[0], need: .list)
        let (limit, offset) = try pageArgs(a[1], a[3])
        var items = try children(mod, dir).compactMap { name -> (String, ModFileIdentity)? in
            let p = (dir.real as NSString).appendingPathComponent(name)
            return ModFileIdentity.lstat(p).map { (p, $0) }
        }
        switch a[2].stringValue {
        case "modifiedDescending": items.sort { $0.1.modified != $1.1.modified ? $0.1.modified > $1.1.modified : $0.0 < $1.0 }
        case "sizeDescending": items.sort { $0.1.size != $1.1.size ? $0.1.size > $1.1.size : $0.0 < $1.0 }
        default: items.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        }
        let page = items.dropFirst(offset).prefix(limit)
        let entries = try page.map { try ref(mod, path: $0.0, scope: childScope(dir.entry.scope), includePath: includePath(mod, dir.entry.scope), includeMeta: true) }
        var o: [String: JSONValue] = ["entries": .array(entries)]
        if offset + page.count < items.count { o["cursor"] = .string(String(offset + page.count)) }
        return .object(o)
    }

    func fsWalk(_ mod: ActiveMod, _ a: [JSONValue]) throws -> JSONValue {
        let dir = try resolve(mod, a[0], need: .walk)
        let maxDepth = min(max(a[1].intValue ?? 1, 1), 8)
        let (limit, offset) = try pageArgs(a[2], a[3])
        var found = [String]()
        var queue = [(dir.real, 0)]
        let cap = offset + limit + 1
        while !queue.isEmpty, found.count < cap {
            let (path, depth) = queue.removeFirst()
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for n in names.sorted() where n != ".DS_Store" {
                let p = (path as NSString).appendingPathComponent(n)
                found.append(p)
                if let id = ModFileIdentity.lstat(p), id.isDirectory, !id.isSymlink, depth + 1 < maxDepth { queue.append((p, depth + 1)) }
                if found.count >= cap { break }
            }
        }
        let page = found.dropFirst(offset).prefix(limit)
        let entries = try page.map { try ref(mod, path: $0, scope: dir.entry.scope, includePath: includePath(mod, dir.entry.scope), includeMeta: true) }
        var o: [String: JSONValue] = ["entries": .array(entries)]
        if found.count > offset + page.count { o["cursor"] = .string(String(offset + page.count)) }
        return .object(o)
    }

    func openRead(_ item: ModResolvedItem) throws -> Int32 {
        let fd = open(item.real, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModCallError.notFound("cannot open the item") }
        do { try verifyDescriptor(fd, item) } catch { close(fd); throw error }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { close(fd); throw ModCallError.invalid("not a regular file") }
        return fd
    }

    func readAll(_ fd: Int32, max: Int) -> (Data, Bool) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < max {
            let n = read(fd, &buf, min(buf.count, max - data.count))
            if n <= 0 { return (data, true) }
            data.append(buf, count: n)
        }
        var probe: UInt8 = 0
        return (data, read(fd, &probe, 1) <= 0)
    }

    func fsReadText(_ mod: ActiveMod, _ a: [JSONValue]) throws -> JSONValue {
        let item = try resolve(mod, a[0], need: .read)
        let max = min(Swift.max(a[1].intValue ?? 0, 0), 512 * 1024)
        let fd = try openRead(item)
        defer { close(fd) }
        var (data, _) = readAll(fd, max: max)
        if data.contains(0) { throw ModCallError("notText", "the item is not text") }
        for _ in 0..<4 {
            if let s = String(data: data, encoding: .utf8) { return .string(s) }
            if data.isEmpty { break }
            data.removeLast()
        }
        throw ModCallError("notText", "the item is not UTF-8 text")
    }

    func fsReadBytes(_ mod: ActiveMod, _ a: [JSONValue]) throws -> JSONValue {
        let item = try resolve(mod, a[0], need: .read)
        guard let offset = a[1].stringValue.flatMap(Int64.init), offset >= 0 else { throw ModCallError.invalid("offset must be a non-negative decimal string") }
        let length = a[2].intValue ?? 0
        guard (0...256 * 1024).contains(length) else { throw ModCallError.limit("length must be 0...262144") }
        let fd = try openRead(item)
        defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { throw ModCallError.invalid("offset out of range") }
        let (data, eof) = readAll(fd, max: length)
        return .object(["base64": .string(data.base64EncodedString()), "eof": .bool(eof)])
    }

    func fsCreate(_ mod: ActiveMod, _ a: [JSONValue], directory: Bool) throws -> JSONValue {
        let dir = try resolve(mod, a[0], need: .write)
        guard ModFileIdentity.lstat(dir.real)?.isDirectory == true else { throw ModCallError.invalid("destination is not a folder") }
        let name = a[1].stringValue ?? ""
        guard ModPathRules.validName(name) else { throw ModCallError("invalidName", "'\(name)' is not a valid file name") }
        let dfd = open(dir.real, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dfd >= 0 else { throw ModCallError.notFound("cannot open the folder") }
        defer { close(dfd) }
        try verifyDescriptor(dfd, dir)
        if directory {
            guard mkdirat(dfd, name, 0o755) == 0 else {
                if errno == EEXIST { throw ModCallError("exists", "'\(name)' already exists") }
                throw ModCallError.denied(String(cString: strerror(errno)))
            }
            return try ref(mod, path: (dir.real as NSString).appendingPathComponent(name), scope: dir.entry.scope, includePath: includePath(mod, dir.entry.scope), includeMeta: true)
        }
        let text = Data((a[2].stringValue ?? "").utf8)
        guard text.count <= 512 * 1024 else { throw ModCallError.limit("text exceeds 512 KiB") }
        var finalName = name
        var fd: Int32 = -1
        let policy = a[3].stringValue ?? "fail"
        for attempt in 1...100 {
            fd = openat(dfd, finalName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if fd >= 0 { break }
            guard errno == EEXIST else { throw ModCallError.denied(String(cString: strerror(errno))) }
            switch policy {
            case "skip":
                return try ref(mod, path: (dir.real as NSString).appendingPathComponent(finalName), scope: dir.entry.scope, includePath: includePath(mod, dir.entry.scope), includeMeta: true)
            case "rename":
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                finalName = ext.isEmpty ? "\(base) \(attempt + 1)" : "\(base) \(attempt + 1).\(ext)"
            default:
                throw ModCallError("exists", "'\(name)' already exists")
            }
        }
        guard fd >= 0 else { throw ModCallError("exists", "no free name for '\(name)'") }
        _ = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        return try ref(mod, path: (dir.real as NSString).appendingPathComponent(finalName), scope: dir.entry.scope, includePath: includePath(mod, dir.entry.scope), includeMeta: true)
    }

    func opsTransfer(_ mod: ActiveMod, _ a: [JSONValue], move: Bool) async throws -> JSONValue {
        guard let ops = deps.fileOperations else { throw ModCallError.denied("file operations are unavailable") }
        let items = try list(a[0], max: 128).map { try resolve(mod, $0, need: move ? .write : .read) }
        let dest = try resolve(mod, a[1], need: .write)
        let conflict = ModConflictPolicy(rawValue: a[2].stringValue ?? "fail") ?? .fail
        let urls = items.map { URL(fileURLWithPath: $0.real) }
        return try await trackExternal(mod, ops) {
            move ? try await ops.move(urls, to: URL(fileURLWithPath: dest.real), conflict: conflict, modId: mod.id)
                 : try await ops.copy(urls, to: URL(fileURLWithPath: dest.real), conflict: conflict, modId: mod.id)
        }
    }

    func trackExternal(_ mod: ActiveMod, _ ops: ModFileOperationsPerforming, _ start: () async throws -> String) async throws -> JSONValue {
        let ledger = deps.ledger
        let owner = mod.id
        try await ledger.reserve(owner: owner, refreshing: ops)
        let id: String
        do {
            id = try await start()
        } catch {
            ledger.release(owner: owner)
            throw error
        }
        ledger.register(id, owner: owner, external: true)
        if let observing = ops as? ModFileOperationsObserving {
            await observing.observeCompletion(id) { progress in ledger.update(id, progress) }
        }
        return .object(["operationId": .string(id)])
    }

    func searchFiles(_ mod: ActiveMod, _ a: [JSONValue]) async throws -> JSONValue {
        let query = (a[0].stringValue ?? "").lowercased()
        let root = try resolve(mod, a[1], need: .list)
        let (limit, offset) = try pageArgs(a[2], a[3])
        var urls: [URL] = []
        var next: String?
        if let search = deps.fileSearch {
            let r = try await search.search(query, under: URL(fileURLWithPath: root.real), limit: limit, cursor: a[3].stringValue)
            urls = r.urls.filter { ModPathRules.contains(root.real, ModPathRules.realpath($0.path) ?? "") }
            next = r.cursor
        } else {
            var matched = [URL]()
            var scanned = 0
            if let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root.real), includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                while let u = en.nextObject() as? URL {
                    scanned += 1
                    if scanned > 20_000 || en.level > 8 { en.skipDescendants(); if scanned > 20_000 { break } }
                    if query.isEmpty || u.lastPathComponent.lowercased().contains(query) { matched.append(u) }
                    if matched.count > offset + limit { break }
                }
            }
            urls = Array(matched.dropFirst(offset).prefix(limit))
            if matched.count > offset + limit { next = String(offset + limit) }
        }
        let results = urls.compactMap { u -> JSONValue? in
            guard let ref = try? ref(mod, path: u.path, scope: root.entry.scope, includePath: true, includeMeta: false), let h = ref["handle"] else { return nil }
            return .object(["id": h, "title": .string(u.lastPathComponent), "subtitle": .string(u.deletingLastPathComponent().path), "handle": h])
        }
        var o: [String: JSONValue] = ["results": .array(results), "done": .bool(next == nil)]
        if let next { o["cursor"] = .string(next) }
        return .object(o)
    }

    func media(_ mod: ActiveMod, _ a: [JSONValue], info: Bool) throws -> JSONValue {
        let items = try list(a[0], max: deps.catalog.limits.batchItems)
        var out = [JSONValue]()
        for v in items {
            let item = try resolve(mod, v, need: .read)
            let handle = v["handle"] ?? .string("")
            var width = 0, height = 0
            var format: String?
            let fd = try? openRead(item)
            if let fd {
                close(fd)
                if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.real) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] {
                    width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
                    height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
                    format = CGImageSourceGetType(src) as String?
                }
            }
            if info {
                guard width > 0, height > 0 else { continue }
                var o: [String: JSONValue] = ["handle": handle, "width": .int(width), "height": .int(height)]
                if let format { o["format"] = .string(format) }
                out.append(.object(o))
            } else if width > 0, height > 0 {
                out.append(.object(["handle": handle, "text": .string("\(width)×\(height)"), "number": .int(width * height), "sortKey": .string(String(format: "%012d", width * height))]))
            } else {
                out.append(.object(["handle": handle]))
            }
        }
        return .array(out)
    }
}
