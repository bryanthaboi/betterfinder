import Foundation
import ModKit
import ModValidation

enum MCPResources {
    static let base = "betterfinder://mod-api/"

    static func entry(_ uri: String, _ name: String, _ title: String, _ description: String, _ mime: String) -> JSONValue {
        obj(["uri": uri.j, "name": name.j, "title": title.j, "description": description.j, "mimeType": mime.j])
    }

    static func mime(forPage name: String) -> String { name.hasSuffix(".md") ? "text/markdown" : "text/plain" }

    static func list(_ server: MCPServer) -> [JSONValue] {
        var out = [JSONValue]()
        out.append(entry(base + "catalog.json", "catalog", "Mod API catalog (JSON)", "Every namespace, function, type, hook, permission, contribution and limit of the installed mod API", "application/json"))
        out.append(entry(base + "reference.md", "reference", "Mod API reference (Markdown)", "Generated reference for the installed mod API", "text/markdown"))
        out.append(entry(base + "diagnostics.md", "diagnostics", "Diagnostic code table", "Every BF diagnostic code with its severity and meaning", "text/markdown"))
        for (name, _) in MCPServer.schemaNames {
            out.append(entry(base + "schemas/\(name).json", "schema-\(name)", "\(name) JSON Schema", "JSON Schema used by the validator", "application/json"))
        }
        for page in ModDocsGenerator.pageNames {
            out.append(entry(base + "docs/\(page)", "doc-\(page)", page, "Generated documentation page", mime(forPage: page)))
        }
        out.append(entry(base + "examples/index.json", "examples", "Example mods", "List of bundled example mods and their files", "application/json"))
        for id in ModExamples.ids {
            guard let example = ModExamples.example(id) else { continue }
            for path in example.package.files.keys.sorted() {
                out.append(entry(base + "examples/\(id)/\(path)", "example-\(id)-\(path)", "\(id)/\(path)", "File of the example mod \(id)", path.hasSuffix(".json") ? "application/json" : "text/plain"))
            }
        }
        out.append(entry(base + "examples/index-listing.example.json", "example-index-listing", "Index listing example", "Example mod index listing", "application/json"))
        return out
    }

    static func templates() -> [JSONValue] {
        [
            obj(["uriTemplate": (base + "docs/{page}").j, "name": "docs-page".j, "title": "Documentation page".j, "mimeType": "text/markdown".j]),
            obj(["uriTemplate": (base + "examples/{id}/{path}").j, "name": "example-file".j, "title": "Example mod file".j, "mimeType": "text/plain".j]),
            obj(["uriTemplate": (base + "schemas/{name}.json").j, "name": "schema".j, "title": "JSON Schema".j, "mimeType": "application/json".j]),
        ]
    }

    static func contents(_ uri: String, _ mime: String, _ text: String) -> JSONValue {
        obj(["uri": uri.j, "mimeType": mime.j, "text": text.j])
    }

    static func diagnosticsTable(_ catalog: ModCatalog) -> String {
        var lines = ["# Diagnostic codes", "", "| Code | Severity | Meaning |", "|---|---|---|"]
        for d in catalog.diagnostics { lines.append("| \(d.code) | \(d.severity.rawValue) | \(d.title.replacingOccurrences(of: "|", with: "\\|")) |") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func read(_ server: MCPServer, uri: String) -> JSONValue? {
        guard uri.hasPrefix(base) else { return nil }
        let rest = String(uri.dropFirst(base.count))
        let catalog = server.configuration.validator.catalog
        switch rest {
        case "catalog.json": return contents(uri, "application/json", String(decoding: catalog.jsonData, as: UTF8.self))
        case "reference.md": return contents(uri, "text/markdown", catalog.markdownReference())
        case "diagnostics.md": return contents(uri, "text/markdown", diagnosticsTable(catalog))
        case "examples/index.json":
            let items = ModExamples.ids.compactMap { id -> JSONValue? in
                guard let e = ModExamples.example(id) else { return nil }
                return obj(["id": id.j, "files": e.package.files.keys.sorted().map { (base + "examples/\(id)/\($0)") }.j])
            }
            return contents(uri, "application/json", JSONValue.array(items).prettyString())
        case "examples/index-listing.example.json":
            guard let data = ModExamples.indexListingExample else { return nil }
            return contents(uri, "application/json", String(decoding: data, as: UTF8.self))
        default: break
        }
        if rest.hasPrefix("schemas/"), rest.hasSuffix(".json") {
            let name = String(rest.dropFirst("schemas/".count).dropLast(".json".count))
            guard let match = MCPServer.schemaNames.first(where: { $0.0 == name }), let url = JSONSchema.resourceURL(match.1.self), let data = try? Data(contentsOf: url) else { return nil }
            return contents(uri, "application/json", String(decoding: data, as: UTF8.self))
        }
        if rest.hasPrefix("docs/") {
            let name = String(rest.dropFirst("docs/".count))
            guard ModDocsGenerator.pageNames.contains(name), let page = ModDocsGenerator.pages(catalog: catalog).first(where: { $0.name == name }) else { return nil }
            return contents(uri, mime(forPage: name), page.contents)
        }
        if rest.hasPrefix("examples/") {
            let parts = rest.dropFirst("examples/".count).split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, ModExamples.ids.contains(parts[0]), let example = ModExamples.example(parts[0]), let data = example.package.files[parts[1]],
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return contents(uri, parts[1].hasSuffix(".json") ? "application/json" : "text/plain", text)
        }
        return nil
    }

    static func docsEntries(catalog: ModCatalog, name: String?) throws -> [JSONValue] {
        let pages = ModDocsGenerator.pages(catalog: catalog)
        if let name {
            let wanted = pages.first { $0.name == name || $0.name == name + ".md" || $0.name.replacingOccurrences(of: ".md", with: "") == name }
            guard let page = wanted else { return [] }
            return [obj(["name": page.name.j, "uri": (base + "docs/" + page.name).j, "markdown": page.contents.j])]
        }
        return pages.map { obj(["name": $0.name.j, "uri": (base + "docs/" + $0.name).j, "bytes": $0.contents.utf8.count.j]) }
    }
}
