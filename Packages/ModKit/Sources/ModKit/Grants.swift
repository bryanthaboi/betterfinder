import Foundation

public struct GrantUse: Equatable, Sendable {
    public var requirement: GrantRequirement
    public var origin: String
    public var pointer: String?
}

public enum ModGrants {
    public static func satisfies(_ p: ModPermission, _ r: GrantRequirement) -> Bool {
        guard p.kind == r.kind else { return false }
        switch r.kind {
        case .fsRead, .fsWrite:
            if let scopes = r.scopes, !scopes.contains(p.scope?.rawValue ?? "") { return false }
            if r.recursive == true, p.recursive != true { return false }
            return true
        case .ui, .uiOverride:
            let have = Set(p.surfaces ?? [])
            return (r.surfaces ?? []).allSatisfy(have.contains)
        case .processExec:
            if r.mode == .unrestricted { return p.mode == .unrestricted }
            if let op = r.brokerOperation { return p.mode == .unrestricted || (p.operations ?? []).contains(op) }
            return true
        case .operationsObserve, .operationsIntercept:
            guard let op = r.fileOperation else { return true }
            return (p.operations ?? []).contains(op.rawValue)
        case .uiSelection, .net, .credentials, .storage:
            return true
        }
    }

    public static func uses(manifest m: ModManifest, catalog: ModCatalog, analysis: ScriptAnalysis?) -> [GrantUse] {
        var out = [GrantUse]()
        for kind in ModContributionKind.allCases {
            let ids = m.contributes.ids(of: kind)
            guard let surface = kind.surface else { continue }
            for i in ids.indices {
                let ptr = "/contributes/\(kind.rawValue)/\(i)"
                out.append(GrantUse(requirement: .ui(surface), origin: "contribution \(kind.rawValue)[\(i)] '\(ids[i])'", pointer: ptr))
                if replaces(m.contributes, kind, i) != nil {
                    out.append(GrantUse(requirement: GrantRequirement(.uiOverride, surfaces: [surface]), origin: "contribution \(kind.rawValue)[\(i)] replaces a built-in", pointer: ptr + "/replaces"))
                }
            }
        }
        for (i, h) in m.hooks.enumerated() {
            guard let sig = catalog.hook(named: h.name, version: h.version) else { continue }
            for r in sig.requires {
                out.append(GrantUse(requirement: r, origin: "hook \(h.name)", pointer: "/hooks/\(i)"))
            }
        }
        if let a = analysis, a.callsKnown {
            for name in a.catalogCalls {
                guard let f = catalog.function(named: name) else { continue }
                for r in f.requires { out.append(GrantUse(requirement: r, origin: "script call \(name)", pointer: nil)) }
            }
        }
        return out
    }

    public static func optionalUses(manifest m: ModManifest, catalog: ModCatalog) -> [GrantUse] {
        var out = [GrantUse]()
        for (i, h) in m.hooks.enumerated() {
            guard let sig = catalog.hook(named: h.name, version: h.version), mentions(sig.input, "FileRef", catalog: catalog) else { continue }
            out.append(GrantUse(requirement: GrantRequirement(.uiSelection), origin: "item metadata in hook \(h.name)", pointer: "/hooks/\(i)"))
        }
        return out
    }

    static func mentions(_ t: ModTypeExpr, _ name: String, catalog: ModCatalog, seen: Set<String> = []) -> Bool {
        switch t {
        case .list(let inner), .optional(let inner): return mentions(inner, name, catalog: catalog, seen: seen)
        case .ref(let r):
            if r == name { return true }
            guard !seen.contains(r), let def = catalog.type(named: r) else { return false }
            let next = seen.union([r])
            if let a = def.aliasOf, mentions(a, name, catalog: catalog, seen: next) { return true }
            return (def.fields ?? []).contains { mentions($0.type, name, catalog: catalog, seen: next) }
        default: return false
        }
    }

    static func replaces(_ c: ModContributions, _ kind: ModContributionKind, _ i: Int) -> String? {
        switch kind {
        case .toolbar: return c.toolbar[i].replaces
        case .sidebarSections: return c.sidebarSections[i].replaces
        case .contextMenu: return c.contextMenu[i].replaces
        case .columns: return c.columns[i].replaces
        case .statusBar: return c.statusBar[i].replaces
        case .previews: return c.previews[i].replaces
        case .views: return c.views[i].replaces
        default: return nil
        }
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home.arpa") { return true }
        if !h.contains("."), !h.contains(":") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        return false
    }

    public static func check(manifest m: ModManifest, catalog: ModCatalog, analysis: ScriptAnalysis?, file: String = "manifest.json") -> [ModDiagnostic] {
        var diags = [ModDiagnostic]()
        func err(_ code: ModDiagnosticCode, _ ptr: String, _ msg: String, fix: String? = nil) {
            diags.append(ModDiagnostic(code, file: file, pointer: ptr, message: msg, fix: fix))
        }
        for (i, p) in m.permissions.enumerated() {
            let ptr = "/permissions/\(i)"
            if m.permissions[..<i].contains(p) { err(.duplicateGrant, ptr, "duplicate of an earlier permission") }
            if let r = p.reason {
                if r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { err(.invalidGrantShape, ptr + "/reason", "reason must not be blank", fix: "Explain why the mod needs this grant") }
                if r.utf8.count > catalog.limits.maxReasonBytes { err(.sizeBound, ptr + "/reason", "reason longer than \(catalog.limits.maxReasonBytes) bytes") }
            }
            if let q = p.quotaBytes, !(1024...16_777_216).contains(q) { err(.sizeBound, ptr + "/quotaBytes", "quotaBytes must be 1024...16777216") }
            if let b = p.maxBytes, !(1...268_435_456).contains(b) { err(.sizeBound, ptr + "/maxBytes", "maxBytes must be 1...268435456") }
            if let eps = p.endpoints {
                if eps.isEmpty { err(.invalidGrantShape, ptr + "/endpoints", "at least one endpoint is required") }
                if eps.count > 32 { err(.sizeBound, ptr + "/endpoints", "more than 32 endpoints") }
                for (j, ep) in eps.enumerated() {
                    if ep.methods.isEmpty { err(.invalidGrantShape, ptr + "/endpoints/\(j)/methods", "at least one method is required") }
                    if ep.scheme == .http { err(.insecureTransport, ptr + "/endpoints/\(j)/scheme", "plain HTTP endpoint \(ep.host)", fix: "Use https") }
                    if isPrivateHost(ep.host), p.allowPrivate != true {
                        err(.privateNetworkDenied, ptr + "/endpoints/\(j)/host", "'\(ep.host)' is a local or private destination", fix: "Set allowPrivate only if the mod truly needs LAN access")
                    }
                }
            }
            if p.kind == .processExec {
                if p.mode == .unrestricted {
                    err(.highTrustExec, ptr, "unrestricted process.exec grants full user-account execution", fix: "Prefer a curated broker operation")
                }
                for (j, op) in (p.operations ?? []).enumerated() where catalog.brokerOperation(named: op) == nil {
                    err(.unknownBrokerOperation, ptr + "/operations/\(j)", "unknown broker operation '\(op)'", fix: "Known: " + catalog.brokerOperations.map(\.name).joined(separator: ", "))
                }
            }
            if p.kind == .operationsObserve || p.kind == .operationsIntercept {
                for (j, op) in (p.operations ?? []).enumerated() where FileOperationName(rawValue: op) == nil {
                    err(.invalidGrantShape, ptr + "/operations/\(j)", "unknown file operation '\(op)'", fix: "One of: " + FileOperationName.allCases.map(\.rawValue).joined(separator: ", "))
                }
            }
            if p.kind == .credentials {
                for (j, d) in (p.destinations ?? []).enumerated() where isPrivateHost(d) {
                    err(.privateNetworkDenied, ptr + "/destinations/\(j)", "credential destination '\(d)' is local or private")
                }
            }
        }

        if let a = analysis, a.callsKnown {
            let declared = Set(m.permissions.filter { $0.kind == .fsRead || $0.kind == .fsWrite }.compactMap(\.rootId))
            for r in a.literalRootIDs where !declared.contains(r) {
                err(.undeclaredRoot, "/permissions", "script resolves root '\(r)' but no fs.read/fs.write grant declares rootId '\(r)'", fix: "Add a grant with scope \"root\" and rootId \"\(r)\"")
            }
        }

        let uses = uses(manifest: m, catalog: catalog, analysis: analysis)
        var reported = Set<String>()
        for u in uses where !m.permissions.contains(where: { satisfies($0, u.requirement) }) {
            let key = u.requirement.summary + "|" + u.origin
            guard reported.insert(key).inserted else { continue }
            err(.missingGrant, u.pointer ?? "/permissions", "\(u.origin) requires grant \(u.requirement.summary)", fix: "Declare a matching permission")
        }

        if let a = analysis, a.callsKnown {
            let optional = optionalUses(manifest: m, catalog: catalog)
            for (i, p) in m.permissions.enumerated() {
                let ptr = "/permissions/\(i)"
                if p.kind == .ui || p.kind == .uiOverride {
                    for (j, s) in (p.surfaces ?? []).enumerated() {
                        let used = uses.contains { $0.requirement.kind == p.kind && ($0.requirement.surfaces ?? []).contains(s) }
                        if !used { err(.unusedGrant, ptr + "/surfaces/\(j)", "surface '\(s.rawValue)' of \(p.kind.rawValue) is never used", fix: "Remove it") }
                    }
                } else if !uses.contains(where: { satisfies(p, $0.requirement) }), !optional.contains(where: { satisfies(p, $0.requirement) }) {
                    err(.unusedGrant, ptr, "permission \(p.kind.rawValue) is never used by any hook, contribution or catalog call", fix: "Remove it")
                }
            }
        }
        return diags
    }
}
