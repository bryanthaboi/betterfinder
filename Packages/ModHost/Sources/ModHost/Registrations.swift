import FileOps
import Foundation
import ModHostProtocol
import ModKit
import Settings

extension ModHostController {
    @MainActor
    func registerContributions(_ mod: ActiveMod, sink: ModUIRegistrySink?, assets: ModAssetRegistering?, settings: ModSettingsStore?) throws -> [ModRegistrationToken] {
        let m = mod.manifest
        let c = m.contributes
        let owner = m.id
        var tokens = [ModRegistrationToken]()
        func id(_ local: String) -> ModContributionID { ModContributionID(modId: owner, localId: local) }
        func cmd(_ raw: String) -> ModCommandReference { ModCommandReference(raw: raw, owner: owner) }
        func handlerDecl(_ hook: String, _ handler: String) -> ModHookDecl? { m.hooks.first { $0.name == hook && $0.handler == handler } }
        do {
            if let sink {
                for x in c.commands {
                    tokens.append(try sink.registerCommand(ModCommandContribution(id: id(x.id), title: x.title, category: x.category, symbolName: x.icon),
                                                           runner: ModCommandProvider(runtime: self, modId: owner, commandId: x.id), owner: owner))
                }
                for x in c.toolbar {
                    tokens.append(try sink.registerToolbarItem(ModToolbarContribution(id: id(x.id), title: x.title, symbolName: x.icon, command: cmd(x.command), replaces: x.replaces), owner: owner))
                }
                for x in c.sidebarSections {
                    let items = x.items.map { ModSidebarContribution.Item(id: $0.id, title: $0.title, symbolName: $0.icon, knownFolder: $0.knownFolder, location: $0.location.map(id)) }
                    tokens.append(try sink.registerSidebarSection(ModSidebarContribution(id: id(x.id), title: x.title, symbolName: x.icon, items: items, replaces: x.replaces), owner: owner))
                }
                for x in c.contextMenu {
                    tokens.append(try sink.registerContextMenuItem(ModContextMenuContribution(id: id(x.id), title: x.title, command: cmd(x.command), target: x.target, replaces: x.replaces), owner: owner))
                }
                for x in c.columns {
                    guard let decl = handlerDecl("column.values", x.handler) else { continue }
                    tokens.append(try sink.registerColumn(ModColumnContribution(id: id(x.id), title: x.title, valueType: x.valueType, width: x.width, sortable: x.sortable ?? true, replaces: x.replaces),
                                                          provider: ModColumnProvider(runtime: self, modId: owner, column: x.id, decl: decl), owner: owner))
                }
                for x in c.statusBar {
                    tokens.append(try sink.registerStatusBarItem(ModStatusBarContribution(id: id(x.id), title: x.title, alignment: x.alignment ?? .trailing, command: x.command.map(cmd), replaces: x.replaces), owner: owner))
                }
                for x in c.panels {
                    tokens.append(try sink.registerPanel(ModPanelContribution(id: id(x.id), title: x.title, edge: x.edge, presentation: x.presentation, symbolName: x.icon), owner: owner))
                }
                for x in c.previews {
                    guard let decl = handlerDecl("preview.render", x.handler) else { continue }
                    tokens.append(try sink.registerPreview(ModPreviewContribution(id: id(x.id), title: x.title, extensions: x.extensions, replaces: x.replaces),
                                                           provider: ModPreviewProvider(runtime: self, modId: owner, provider: x.id, decl: decl), owner: owner))
                }
                for x in c.views {
                    tokens.append(try sink.registerView(ModViewContribution(id: id(x.id), title: x.title, layout: x.layout, columns: (x.columns ?? []).map(id), symbolName: x.icon, replaces: x.replaces), owner: owner))
                }
                for x in c.locations {
                    guard let decl = handlerDecl("location.list", x.handler) else { continue }
                    tokens.append(try sink.registerLocation(ModLocationContribution(id: id(x.id), title: x.title, scheme: x.scheme, readOnly: x.readOnly, symbolName: x.icon),
                                                            provider: ModLocationProvider(runtime: self, modId: owner, location: x.id, decl: decl), owner: owner))
                }
                for x in c.searchProviders {
                    guard let decl = handlerDecl("search.query", x.handler) else { continue }
                    tokens.append(try sink.registerSearchProvider(ModSearchProviderContribution(id: id(x.id), title: x.title, symbolName: x.icon),
                                                                  search: ModSearchProvider(runtime: self, modId: owner, provider: x.id, decl: decl), owner: owner))
                }
                for x in c.keybindings {
                    tokens.append(try sink.registerKeybinding(ModKeybindingContribution(id: id(x.id), chord: x.key, command: cmd(x.command)), owner: owner))
                }
            }
            if let assets {
                tokens += try assets.register(manifest: m, snapshot: mod.snapshot, settings: settings, owner: owner)
            }
        } catch {
            tokens.forEach { $0.cancel() }
            throw error
        }
        return tokens
    }

    func registerFileOpHook(_ mod: ActiveMod, record: ModLiveRecord) -> FileOpsRegistrationToken? {
        guard let registry = deps.hookRegistry else { return nil }
        let names = Set(mod.manifest.hooks.map(\.name))
        guard names.contains(where: { $0.hasPrefix("fileop.") }) else { return nil }
        let priority = store.state(mod.id)?.priority ?? 0
        let hook = ModFileOperationHook(runtime: self, mod: mod, record: record, priority: priority)
        return registry.register(hook, owner: mod.manifest.name, timeout: Double(catalog.hook(named: "fileop.before.copy", version: 1)?.deadlineMs ?? 1000) / 1000 + Double(options.deadlineGraceMs) / 1000)
    }
}

final class ModColumnProvider: ModColumnValuesProviding, @unchecked Sendable {
    weak var runtime: ModHostController?
    let modId: String
    let column: String
    let decl: ModHookDecl

    init(runtime: ModHostController, modId: String, column: String, decl: ModHookDecl) {
        self.runtime = runtime; self.modId = modId; self.column = column; self.decl = decl
    }

    func values(for items: [URL], revision: Int) async throws -> [URL: ModCellValue] {
        guard let runtime, let mod = runtime.activeMod(modId) else { throw ModInvocationError.notActive(modId) }
        var out = [URL: ModCellValue]()
        var start = 0
        let batch = runtime.catalog.limits.batchItems
        while start < items.count {
            try Task.checkCancellation()
            let chunk = Array(items[start..<min(items.count, start + batch)])
            start += batch
            var byHandle = [String: URL]()
            let broker = runtime.broker
            let column = column
            let r = await runtime.invoke(mod, decl: decl, input: { inv in
                let refs = broker.makeRefs(mod, urls: chunk, invocation: inv)
                for (ref, url) in zip(refs, chunk) { if let h = ref["handle"]?.stringValue { byHandle[h] = url } }
                return .object(["column": .string(column), "items": .array(refs), "revision": .int(revision)])
            }, gesture: false)
            for v in try r.get().arrayValue ?? [] {
                guard let h = v["handle"]?.stringValue, let url = byHandle[h] else { continue }
                out[url] = ModCellValue.from(v)
            }
        }
        return out
    }
}

final class ModPreviewProvider: ModPreviewProviding, @unchecked Sendable {
    weak var runtime: ModHostController?
    let modId: String
    let provider: String
    let decl: ModHookDecl

    init(runtime: ModHostController, modId: String, provider: String, decl: ModHookDecl) {
        self.runtime = runtime; self.modId = modId; self.provider = provider; self.decl = decl
    }

    func render(_ item: URL, maxBytes: Int, dark: Bool) async throws -> ModPreviewContent {
        guard let runtime, let mod = runtime.activeMod(modId) else { throw ModInvocationError.notActive(modId) }
        let broker = runtime.broker
        let provider = provider
        let r = await runtime.invoke(mod, decl: decl, input: { inv in
            let ref = broker.makeRefs(mod, urls: [item], invocation: inv).first ?? .object(["handle": .string(""), "name": .string(item.lastPathComponent), "kind": .string("file")])
            return .object(["provider": .string(provider), "item": ref, "maxBytes": .int(min(max(maxBytes, 0), 512 * 1024)), "appearance": .string(dark ? "dark" : "light")])
        }, gesture: false)
        let v = try r.get()
        guard let node = v["node"].flatMap({ ModUINode.from($0, owner: mod.id) }) else { throw ModInvocationError.invalidOutput("preview node") }
        return ModPreviewContent(title: v["title"]?.stringValue, node: node)
    }
}

final class ModLocationProvider: ModLocationProviding, @unchecked Sendable {
    weak var runtime: ModHostController?
    let modId: String
    let location: String
    let decl: ModHookDecl

    init(runtime: ModHostController, modId: String, location: String, decl: ModHookDecl) {
        self.runtime = runtime; self.modId = modId; self.location = location; self.decl = decl
    }

    func list(path: String, limit: Int, cursor: String?) async throws -> ModLocationPage {
        guard let runtime, let mod = runtime.activeMod(modId) else { throw ModInvocationError.notActive(modId) }
        let location = location
        let r = await runtime.invoke(mod, decl: decl, input: { _ in
            var o: [String: JSONValue] = ["location": .string(location), "path": .string(path), "limit": .int(min(max(limit, 1), 128))]
            if let cursor { o["cursor"] = .string(cursor) }
            return .object(o)
        }, gesture: false)
        let v = try r.get()
        let iso = ISO8601DateFormatter()
        let items = (v["items"]?.arrayValue ?? []).compactMap { e -> ModResourceEntry? in
            guard let id = e["id"]?.stringValue, let name = e["name"]?.stringValue, let kind = e["kind"]?.stringValue else { return nil }
            return ModResourceEntry(id: id, name: name, kind: kind, size: e["size"]?.stringValue.flatMap { Int64($0) }, modified: e["modified"]?.stringValue.flatMap(iso.date(from:)))
        }
        return ModLocationPage(items: items, cursor: v["cursor"]?.stringValue)
    }
}

final class ModSearchProvider: ModSearchProviding, @unchecked Sendable {
    weak var runtime: ModHostController?
    let modId: String
    let provider: String
    let decl: ModHookDecl

    init(runtime: ModHostController, modId: String, provider: String, decl: ModHookDecl) {
        self.runtime = runtime; self.modId = modId; self.provider = provider; self.decl = decl
    }

    func search(_ query: String, scope: URL?, limit: Int) -> AsyncThrowingStream<ModSearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let runtime = self.runtime, let mod = runtime.activeMod(self.modId) else {
                    continuation.finish(throwing: ModInvocationError.notActive(self.modId)); return
                }
                var cursor: String?
                for _ in 0..<10 {
                    if Task.isCancelled { break }
                    let broker = runtime.broker
                    let provider = self.provider
                    let c = cursor
                    let r = await runtime.invoke(mod, decl: self.decl, input: { inv in
                        var o: [String: JSONValue] = ["provider": .string(provider), "query": .string(String(query.prefix(1024))), "limit": .int(min(max(limit, 1), 128))]
                        if let c { o["cursor"] = .string(c) }
                        if let scope, let ref = broker.makeRefs(mod, urls: [scope], invocation: inv).first { o["scope"] = ref }
                        return .object(o)
                    }, gesture: false)
                    switch r {
                    case .failure(let e): continuation.finish(throwing: e); return
                    case .success(let v):
                        let hits = (v["results"]?.arrayValue ?? []).compactMap { h -> ModSearchHit? in
                            guard let id = h["id"]?.stringValue, let title = h["title"]?.stringValue else { return nil }
                            let url = h["handle"]?.stringValue.flatMap { mod.handles.lookup($0, generation: mod.generation) }.map { URL(fileURLWithPath: $0.path) }
                            return ModSearchHit(id: id, title: title, subtitle: h["subtitle"]?.stringValue, url: url)
                        }
                        let done = v["done"]?.boolValue ?? true
                        cursor = v["cursor"]?.stringValue
                        continuation.yield(ModSearchBatch(results: hits, done: done, cursor: cursor))
                        if done || cursor == nil { continuation.finish(); return }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class ModCommandProvider: ModCommandRunning, @unchecked Sendable {
    weak var runtime: ModHostController?
    let modId: String
    let commandId: String

    init(runtime: ModHostController, modId: String, commandId: String) {
        self.runtime = runtime; self.modId = modId; self.commandId = commandId
    }

    func run(selection: [URL], args: JSONValue?) async throws -> ModCommandOutcome {
        guard let runtime else { throw ModInvocationError.notActive(modId) }
        let v = try await runtime.runCommand(modId: modId, commandId: commandId, selection: selection, args: args, parent: nil)
        return ModCommandOutcome(message: v["message"]?.stringValue, operationId: v["operationId"]?.stringValue)
    }
}

final class ModFileOperationHook: FileOperationHook, @unchecked Sendable {
    weak var runtime: ModHostController?
    let mod: ActiveMod
    weak var record: ModLiveRecord?
    let id: String
    let priority: Int

    init(runtime: ModHostController, mod: ActiveMod, record: ModLiveRecord, priority: Int) {
        self.runtime = runtime
        self.mod = mod
        self.record = record
        self.id = "mod.\(mod.id)"
        self.priority = priority
    }

    static func operation(_ k: OperationKind) -> FileOperationName? {
        switch k {
        case .copy, .duplicate: return .copy
        case .move: return .move
        case .trash, .delete: return .trash
        case .rename, .batchRename: return .rename
        default: return nil
        }
    }

    static func origin(_ o: OperationOrigin) -> String {
        switch o {
        case .user: return "user"
        case .undo, .redo: return "undo"
        case .retry: return "retry"
        case .mod: return "mod"
        }
    }

    func granted(_ kind: ModPermissionKind, _ op: FileOperationName) -> Bool {
        mod.grants.contains { $0.kind == kind && ($0.operations ?? []).contains(op.rawValue) }
    }

    func before(_ snapshot: OperationSnapshot) async throws -> HookDecision {
        guard let runtime, let op = Self.operation(snapshot.kind), granted(.operationsIntercept, op),
              let decl = mod.handlers(for: "fileop.before.\(op.rawValue)").first else { return .allow }
        record?.activeOperationHooks += 1
        defer { record?.activeOperationHooks -= 1 }
        let broker = runtime.broker
        let mod = mod
        let r = await runtime.invoke(mod, decl: decl, input: { inv in
            let urls = snapshot.items.map { $0.source ?? $0.destination ?? URL(fileURLWithPath: "/") }
            let refs = broker.makeRefs(mod, urls: urls, invocation: inv)
            let items: [JSONValue] = zip(snapshot.items, refs).map { item, ref in
                var o: [String: JSONValue] = ["itemId": .string(item.id.uuidString), "source": ref]
                if let d = item.destination { o["destinationName"] = .string(d.lastPathComponent) }
                return .object(o)
            }
            return .object([
                "operationId": .string(snapshot.operationID.uuidString), "attemptId": .string(snapshot.attemptID.uuidString),
                "origin": .string(Self.origin(snapshot.origin)), "operation": .string(op.rawValue), "items": .array(items),
            ])
        }, gesture: false)
        let v = try r.get()
        if v["decision"]?.stringValue == "deny" { return .deny(v["reason"]?.stringValue ?? "denied by \(mod.manifest.name)") }
        return .allow
    }

    func after(_ snapshot: OperationSnapshot, _ outcome: OperationOutcome) async throws {
        guard let runtime, let op = Self.operation(snapshot.kind), granted(.operationsObserve, op),
              let decl = mod.handlers(for: "fileop.after.\(op.rawValue)").first else { return }
        let broker = runtime.broker
        let mod = mod
        _ = await runtime.invoke(mod, decl: decl, input: { inv in
            let urls = outcome.items.map { $0.item.source ?? $0.item.destination ?? URL(fileURLWithPath: "/") }
            let refs = broker.makeRefs(mod, urls: urls, invocation: inv)
            let outcomes: [JSONValue] = zip(outcome.items, refs).map { item, ref in
                var o: [String: JSONValue] = ["itemId": .string(item.item.id.uuidString), "source": ref]
                switch item.result {
                case .committed: o["status"] = .string("succeeded")
                case .skipped: o["status"] = .string("skipped")
                case .failed(let e): o["status"] = .string("failed"); o["error"] = .string(e.message)
                }
                return .object(o)
            }
            return .object([
                "operationId": .string(snapshot.operationID.uuidString), "attemptId": .string(snapshot.attemptID.uuidString),
                "origin": .string(Self.origin(snapshot.origin)), "operation": .string(op.rawValue),
                "partial": .bool(outcome.isPartialFailure), "outcomes": .array(outcomes),
            ])
        }, gesture: false)
    }
}
