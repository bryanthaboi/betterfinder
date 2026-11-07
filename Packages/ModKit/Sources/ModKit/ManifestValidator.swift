import Foundation

public struct ModHostVersions: Equatable, Sendable {
    public var app: SemVer
    public var api: SemVer

    public init(app: SemVer, api: SemVer) { self.app = app; self.api = api }

    public static let current = ModHostVersions(app: SemVer(1, 0, 0), api: SemVer(1, 0, 0))
}

public struct ModManifestFindings: Sendable {
    public var manifest: [ModDiagnostic] = []
    public var grants: [ModDiagnostic] = []
    public var paths: [ModDiagnostic] = []

    public var all: [ModDiagnostic] { manifest + grants + paths }
}

public enum ModManifestValidator {
    public static let reservedPrefixes = ["betterfinder.", "builtin.", "apple.", "com.apple."]

    public static func validate(
        _ m: ModManifest, package: ModPackage?, host: ModHostVersions = .current, catalog: ModCatalog = .v1,
        analysis: ScriptAnalysis? = nil, file: String = "manifest.json"
    ) -> ModManifestFindings {
        var out = ModManifestFindings()
        out.manifest = semantics(m, host: host, catalog: catalog, analysis: analysis, file: file)
        out.grants = ModGrants.check(manifest: m, catalog: catalog, analysis: analysis, file: file)
        out.paths = paths(m, package: package, file: file)
        return out
    }

    static func semantics(_ m: ModManifest, host: ModHostVersions, catalog: ModCatalog, analysis: ScriptAnalysis?, file: String) -> [ModDiagnostic] {
        var d = [ModDiagnostic]()
        func err(_ code: ModDiagnosticCode, _ ptr: String, _ msg: String, fix: String? = nil) {
            d.append(ModDiagnostic(code, file: file, pointer: ptr, message: msg, fix: fix))
        }
        let limits = catalog.limits
        let c = m.contributes

        for p in reservedPrefixes where m.id.hasPrefix(p) { err(.reservedNamespace, "/id", "ids starting with '\(p)' are reserved for the host") }
        if !m.id.hasPrefix(m.author.lowercased() + ".") {
            err(.idAuthorMismatch, "/id", "id '\(m.id)' must start with '\(m.author.lowercased()).'", fix: "Rename the id to \(m.author.lowercased()).<name>")
        }
        if m.name.count > 80 { err(.sizeBound, "/name", "name longer than 80 characters") }
        if m.license.isEmpty || m.license.count > 64 { err(.invalidValue, "/license", "license must be 1-64 characters (SPDX id recommended)") }

        if !m.api.contains(host.api) { err(.apiIncompatible, "/api", "api range '\(m.api)' does not include host API \(host.api)", fix: "Target a range containing \(host.api)") }
        if !m.app.contains(host.app) { err(.appIncompatible, "/app", "app range '\(m.app)' does not include host app \(host.app)") }
        if !m.api.hasUpperBound { err(.unboundedRange, "/api", "api range has no upper bound; breaking majors will not be excluded", fix: "Add an upper bound such as <2.0.0") }
        if !m.app.hasUpperBound { err(.unboundedRange, "/app", "app range has no upper bound", fix: "Add an upper bound such as <2.0.0") }

        if m.permissions.count > limits.maxPermissions { err(.sizeBound, "/permissions", "more than \(limits.maxPermissions) permissions") }
        if m.hooks.count > limits.maxHooks { err(.sizeBound, "/hooks", "more than \(limits.maxHooks) hooks") }
        if m.settings.count > limits.maxSettings { err(.sizeBound, "/settings", "more than \(limits.maxSettings) settings") }
        if m.dependencies.count > limits.maxDependencies { err(.sizeBound, "/dependencies", "more than \(limits.maxDependencies) dependencies") }
        if m.conflicts.count > limits.maxConflicts { err(.sizeBound, "/conflicts", "more than \(limits.maxConflicts) conflicts") }

        switch m.runtime {
        case .data:
            if m.entry != nil { err(.entryForbidden, "/entry", "data/1 mods must not declare an entry", fix: "Remove 'entry' or use runtime jsc-ir/1") }
            for (i, _) in m.hooks.enumerated() { err(.handlerInDataMod, "/hooks/\(i)", "data/1 mods cannot declare hooks") }
            for kind in [ModContributionKind.columns, .previews, .locations, .commands, .searchProviders] {
                for i in c.ids(of: kind).indices { err(.handlerInDataMod, "/contributes/\(kind.rawValue)/\(i)", "'\(kind.rawValue)' needs a script handler; data/1 mods cannot contribute it") }
            }
        default:
            guard let entry = m.entry else { err(.entryInvalid, "/entry", "runtime \(m.runtime.rawValue) requires an entry", fix: "Add \"entry\""); break }
            if !m.runtime.allowedEntryExtensions.contains(where: { entry.hasSuffix($0) }) {
                err(.entryInvalid, "/entry", "entry '\(entry)' must end with " + m.runtime.allowedEntryExtensions.joined(separator: " or ") + " for \(m.runtime.rawValue)")
            }
        }

        for kind in ModContributionKind.allCases {
            let ids = c.ids(of: kind)
            if ids.count > limits.maxContributionsPerKind { err(.sizeBound, "/contributes/\(kind.rawValue)", "more than \(limits.maxContributionsPerKind) entries") }
            var seen = Set<String>()
            for (i, id) in ids.enumerated() where !seen.insert(id).inserted {
                err(.duplicateID, "/contributes/\(kind.rawValue)/\(i)/id", "duplicate \(kind.rawValue) id '\(id)'")
            }
        }

        let commandIDs = Set(c.commands.map(\.id))
        let locationIDs = Set(c.locations.map(\.id))
        let columnIDs = Set(c.columns.map(\.id))
        func commandRef(_ ref: String, _ ptr: String) {
            if ref.hasPrefix("builtin.") { return }
            if !commandIDs.contains(ref) { err(.unknownReference, ptr, "command '\(ref)' is not declared in contributes.commands", fix: "Declare it or reference a builtin.* command") }
        }
        for (i, t) in c.toolbar.enumerated() { commandRef(t.command, "/contributes/toolbar/\(i)/command") }
        for (i, t) in c.contextMenu.enumerated() { commandRef(t.command, "/contributes/contextMenu/\(i)/command") }
        for (i, t) in c.statusBar.enumerated() { if let cmd = t.command { commandRef(cmd, "/contributes/statusBar/\(i)/command") } }
        for (i, t) in c.keybindings.enumerated() { commandRef(t.command, "/contributes/keybindings/\(i)/command") }
        for (i, s) in c.sidebarSections.enumerated() {
            for (j, item) in s.items.enumerated() {
                if let loc = item.location, !locationIDs.contains(loc) {
                    err(.unknownReference, "/contributes/sidebarSections/\(i)/items/\(j)/location", "location '\(loc)' is not declared in contributes.locations")
                }
            }
        }
        for (i, v) in c.views.enumerated() {
            for (j, col) in (v.columns ?? []).enumerated() where !columnIDs.contains(col) {
                err(.unknownReference, "/contributes/views/\(i)/columns/\(j)", "column '\(col)' is not declared in contributes.columns")
            }
        }
        let settingKeys = Set(m.settings.map(\.key))
        for (i, p) in c.settingsPanes.enumerated() {
            for (j, key) in p.settings.enumerated() where !settingKeys.contains(key) {
                err(.unknownReference, "/contributes/settingsPanes/\(i)/settings/\(j)", "setting '\(key)' is not declared in settings")
            }
        }
        var chords = [String: Int]()
        for (i, k) in c.keybindings.enumerated() {
            if let prev = chords[k.key] { err(.duplicateKeybinding, "/contributes/keybindings/\(i)/key", "chord '\(k.key)' already bound by keybindings[\(prev)]") }
            else { chords[k.key] = i }
            let mods = k.key.split(separator: "+").dropLast()
            if !mods.contains(where: { $0 == "cmd" || $0 == "ctrl" || $0 == "opt" }), !k.key.hasPrefix("f") || k.key.count > 3 {
                err(.keybindingNoModifier, "/contributes/keybindings/\(i)/key", "chord '\(k.key)' has no command/control/option modifier and would hijack typing")
            }
        }

        var seenKeys = Set<String>()
        for (i, s) in m.settings.enumerated() {
            if !seenKeys.insert(s.key).inserted { err(.duplicateID, "/settings/\(i)/key", "duplicate setting key '\(s.key)'") }
            let lower = s.key.lowercased()
            if s.type == .string, ["password", "secret", "token", "apikey"].contains(where: lower.contains) {
                err(.secretInSettings, "/settings/\(i)/key", "'\(s.key)' looks like a secret; settings are stored unencrypted", fix: "Use the credentials grant instead")
            }
        }

        var seenDeps = Set<String>()
        for (i, dep) in m.dependencies.enumerated() {
            if dep.id == m.id { err(.selfDependency, "/dependencies/\(i)/id", "mod depends on itself") }
            if !seenDeps.insert(dep.id).inserted { err(.duplicateID, "/dependencies/\(i)/id", "duplicate dependency '\(dep.id)'") }
            if m.conflicts.contains(dep.id) { err(.dependencyConflict, "/dependencies/\(i)/id", "'\(dep.id)' is both a dependency and a conflict") }
        }
        for (i, id) in m.conflicts.enumerated() where id == m.id { err(.dependencyConflict, "/conflicts/\(i)", "mod conflicts with itself") }

        var hookKeys = Set<String>()
        var hookNamesSeen = [String: Int]()
        for (i, h) in m.hooks.enumerated() {
            let ptr = "/hooks/\(i)"
            guard !catalog.hooks(named: h.name).isEmpty else {
                err(.unknownHook, ptr + "/name", "unknown hook '\(h.name)'", fix: "Known: " + catalog.hookNames.joined(separator: ", "))
                continue
            }
            guard let sig = catalog.hook(named: h.name, version: h.version) else {
                err(.unsupportedHookVersion, ptr + "/version", "hook '\(h.name)' has no version \(h.version); latest is \(catalog.latestHookVersions[h.name] ?? 0)")
                continue
            }
            if !hookKeys.insert("\(h.name)|\(h.handler)").inserted { err(.duplicateHook, ptr, "hook '\(h.name)' is already bound to handler '\(h.handler)'") }
            else if !sig.multiple, hookNamesSeen[h.name] != nil { err(.duplicateHook, ptr, "hook '\(h.name)' may be declared only once") }
            hookNamesSeen[h.name] = i
            if let a = analysis, !a.handlers.isEmpty || m.runtime == .jscIR {
                if let found = a.handlers[h.handler] {
                    if !found.isEmpty, found != sig.signatureID {
                        err(.handlerHookMismatch, ptr + "/handler", "script function '\(h.handler)' implements \(found) but the manifest binds it to \(sig.signatureID)")
                    }
                } else {
                    err(.missingHandlerFunction, ptr + "/handler", "script defines no function '\(h.handler)'", fix: "Define it in the entry script")
                }
            }
        }

        func bound(_ hook: String, _ handler: String) -> Bool { m.hooks.contains { $0.name == hook && $0.handler == handler } }
        func bind(_ kind: ModContributionKind, _ i: Int, _ handler: String) {
            guard let hook = kind.hookName else { return }
            if !bound(hook, handler) {
                err(.handlerHookMismatch, "/contributes/\(kind.rawValue)/\(i)/handler", "handler '\(handler)' is not bound to hook '\(hook)'", fix: "Add {\"name\":\"\(hook)\",\"handler\":\"\(handler)\",\"version\":1} to hooks")
            }
        }
        for (i, x) in c.columns.enumerated() { bind(.columns, i, x.handler) }
        for (i, x) in c.previews.enumerated() { bind(.previews, i, x.handler) }
        for (i, x) in c.locations.enumerated() { bind(.locations, i, x.handler) }
        for (i, x) in c.commands.enumerated() { bind(.commands, i, x.handler) }
        for (i, x) in c.searchProviders.enumerated() { bind(.searchProviders, i, x.handler) }

        var referenced = Set<String>()
        for kind in ModContributionKind.allCases {
            guard let hook = kind.hookName else { continue }
            switch kind {
            case .columns: c.columns.forEach { referenced.insert("\(hook)|\($0.handler)") }
            case .previews: c.previews.forEach { referenced.insert("\(hook)|\($0.handler)") }
            case .locations: c.locations.forEach { referenced.insert("\(hook)|\($0.handler)") }
            case .commands: c.commands.forEach { referenced.insert("\(hook)|\($0.handler)") }
            case .searchProviders: c.searchProviders.forEach { referenced.insert("\(hook)|\($0.handler)") }
            default: break
            }
        }
        for (i, h) in m.hooks.enumerated() {
            guard let sig = catalog.hook(named: h.name, version: h.version), sig.multiple else { continue }
            if !referenced.contains("\(h.name)|\(h.handler)") {
                err(.unusedHook, "/hooks/\(i)", "hook '\(h.name)' handler '\(h.handler)' is not referenced by any \(sig.contribution ?? "contribution")", fix: "Remove it or add the contribution")
            }
        }
        if let a = analysis, m.runtime == .jscIR {
            let bound = Set(m.hooks.map(\.handler))
            for name in a.handlers.keys.sorted() where !bound.contains(name) {
                d.append(ModDiagnostic(.unusedFunction, file: m.entry, pointer: "/functions/\(name)", message: "function '\(name)' implements a hook signature but the manifest never binds it", fix: "Add it to hooks or remove it"))
            }
        }
        return d
    }

    static func paths(_ m: ModManifest, package: ModPackage?, file: String) -> [ModDiagnostic] {
        var d = [ModDiagnostic]()
        guard let package else { return d }
        d += package.inventoryDiagnostics
        func check(_ path: String, _ ptr: String, directory: Bool) {
            guard ModPatterns.matches(path, ModPatterns.relativePath) else {
                d.append(ModDiagnostic(.pathNotContained, file: file, pointer: ptr, message: "'\(path)' is not a contained relative path"))
                return
            }
            let ok = directory ? package.isDirectory(path) : package.exists(path)
            if !ok { d.append(ModDiagnostic(.pathMissing, file: file, pointer: ptr, message: "'\(path)' does not exist in the package")) }
        }
        if let e = m.entry { check(e, "/entry", directory: false) }
        for (i, t) in m.contributes.themes.enumerated() { check(t.path, "/contributes/themes/\(i)/path", directory: false) }
        for (i, t) in m.contributes.iconSets.enumerated() { check(t.path, "/contributes/iconSets/\(i)/path", directory: true) }
        for (i, t) in m.contributes.sounds.enumerated() { check(t.path, "/contributes/sounds/\(i)/path", directory: true) }
        return d
    }
}

public struct InstalledMod: Sendable {
    public var manifest: ModManifest
    public var archiveSHA256: String?

    public init(manifest: ModManifest, archiveSHA256: String? = nil) { self.manifest = manifest; self.archiveSHA256 = archiveSHA256 }
}

public enum ModInstallSetValidator {
    public static func validate(_ mods: [InstalledMod]) -> [ModDiagnostic] {
        var d = [ModDiagnostic]()
        let byID = Dictionary(mods.map { ($0.manifest.id, $0) }, uniquingKeysWith: { a, _ in a })
        for mod in mods {
            let m = mod.manifest
            for (i, dep) in m.dependencies.enumerated() {
                let ptr = "/dependencies/\(i)"
                guard let have = byID[dep.id] else {
                    d.append(ModDiagnostic(.dependencyUnsatisfied, file: m.id, pointer: ptr, message: "dependency '\(dep.id)' \(dep.version) is not installed"))
                    continue
                }
                if have.manifest.version != dep.version {
                    d.append(ModDiagnostic(.dependencyUnsatisfied, file: m.id, pointer: ptr, message: "dependency '\(dep.id)' is \(have.manifest.version); '\(m.id)' pins \(dep.version)"))
                } else if let sha = have.archiveSHA256, sha != dep.sha256 {
                    d.append(ModDiagnostic(.dependencyUnsatisfied, file: m.id, pointer: ptr + "/sha256", message: "dependency '\(dep.id)' archive hash differs from the pinned sha256"))
                }
            }
            for (i, c) in m.conflicts.enumerated() where byID[c] != nil {
                d.append(ModDiagnostic(.installedConflict, file: m.id, pointer: "/conflicts/\(i)", message: "'\(m.id)' conflicts with installed '\(c)'"))
            }
        }
        var state = [String: Int]()
        var reported = Set<String>()
        func visit(_ id: String, _ stack: [String]) {
            if state[id] == 2 { return }
            if state[id] == 1 {
                let cycle = Array(stack.drop(while: { $0 != id })) + [id]
                let key = cycle.dropLast().sorted().joined(separator: ",")
                if reported.insert(key).inserted {
                    d.append(ModDiagnostic(.dependencyCycle, file: id, message: "dependency cycle: " + cycle.joined(separator: " → ")))
                }
                return
            }
            state[id] = 1
            for dep in byID[id]?.manifest.dependencies ?? [] where byID[dep.id] != nil { visit(dep.id, stack + [id]) }
            state[id] = 2
        }
        for id in byID.keys.sorted() { visit(id, []) }
        return d
    }
}
