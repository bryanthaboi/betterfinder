import Foundation
import ModKit

public enum ScaffoldLanguage: String, CaseIterable, Sendable { case bfscript, ts, js }

public enum ScaffoldTemplate: String, CaseIterable, Sendable {
    case column, sidebar, toolbar, panel, preview, command, theme

    public var isDataOnly: Bool { self == .sidebar || self == .theme }
}

public struct ScaffoldFile: Equatable, Sendable {
    public var path: String
    public var contents: String
}

public enum ScaffoldError: Error, CustomStringConvertible, Equatable {
    case invalidID(String)

    public var description: String {
        switch self {
        case .invalidID(let id): return "'\(id)' is not a valid mod id: use author.name with lowercase letters, digits, '.' and '-' (3-95 characters)"
        }
    }
}

public enum ModScaffold {
    public static func author(of id: String) -> String { String(id.split(separator: ".", maxSplits: 1).first ?? "") }

    public static func displayName(of id: String) -> String {
        let local = id.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? id
        return local.split(whereSeparator: { $0 == "-" || $0 == "." }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public static func validateID(_ id: String) throws {
        guard ModPatterns.matches(id, ModPatterns.modID), id.contains("."), ModPatterns.matches(author(of: id), ModPatterns.author),
              !id.hasSuffix("."), !id.hasSuffix("-") else { throw ScaffoldError.invalidID(id) }
        let rest = id.split(separator: ".", maxSplits: 1)
        guard rest.count == 2, !rest[1].isEmpty else { throw ScaffoldError.invalidID(id) }
    }

    public static func files(id: String, language: ScaffoldLanguage, template: ScaffoldTemplate, catalog: ModCatalog = .v1) throws -> [ScaffoldFile] {
        try validateID(id)
        let name = displayName(of: id)
        let authorName = ModScaffold.author(of: id)
        let effective: ScaffoldLanguage? = template.isDataOnly ? nil : language
        var files = [ScaffoldFile]()

        let spec = templateSpec(template, language: effective, name: name, id: id)
        files.append(ScaffoldFile(path: "manifest.json", contents: manifest(id: id, name: name, author: authorName, runtime: runtime(effective), entry: entry(effective), spec: spec)))
        if let script = spec.script, let effective {
            files.append(ScaffoldFile(path: entry(effective)!, contents: script))
        }
        files += spec.extraFiles
        files.append(ScaffoldFile(path: "README.md", contents: readme(id: id, name: name, language: effective, template: template)))
        files.append(ScaffoldFile(path: "LICENSE", contents: license(author: authorName)))
        if effective == .ts || effective == .js {
            files.append(ScaffoldFile(path: "betterfinder.d.ts", contents: ModCatalogAdapter.declarations(from: catalog)))
            files.append(ScaffoldFile(path: "tsconfig.json", contents: tsconfig))
        }
        files.append(ScaffoldFile(path: ".gitignore", contents: ".DS_Store\n*.bfmod\n*.bfmod.receipt.json\n"))
        return files.sorted { $0.path < $1.path }
    }

    @discardableResult
    public static func write(_ files: [ScaffoldFile], to directory: URL) throws -> [String] {
        let fm = FileManager.default
        if let existing = try? fm.contentsOfDirectory(atPath: directory.path), !existing.isEmpty {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path, NSLocalizedDescriptionKey: "\(directory.path) already exists and is not empty"])
        }
        for f in files {
            let url = directory.appendingPathComponent(f.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.contents.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        return files.map(\.path)
    }

    static func runtime(_ language: ScaffoldLanguage?) -> String {
        switch language {
        case .bfscript: return "jsc-ir/1"
        case .ts: return "ts/1"
        case .js: return "js/1"
        case nil: return "data/1"
        }
    }

    static func entry(_ language: ScaffoldLanguage?) -> String? {
        switch language {
        case .bfscript: return "scripts/main.bfscript.json"
        case .ts: return "scripts/main.ts"
        case .js: return "scripts/main.js"
        case nil: return nil
        }
    }

    struct Spec {
        var permissions: [String] = []
        var contributes: [String: String] = [:]
        var hooks: [(name: String, handler: String)] = []
        var script: String?
        var extraFiles: [ScaffoldFile] = []
    }

    static let contributionOrder = ["toolbar", "sidebarSections", "columns", "panels", "previews", "commands", "themes"]

    static func manifest(id: String, name: String, author: String, runtime: String, entry: String?, spec: Spec) -> String {
        var lines = [String]()
        lines.append("{")
        lines.append("  \"manifestVersion\": 1,")
        lines.append("  \"id\": \"\(id)\",")
        lines.append("  \"name\": \"\(name)\",")
        lines.append("  \"author\": \"\(author)\",")
        lines.append("  \"version\": \"0.1.0\",")
        lines.append("  \"api\": \">=1.0.0 <2.0.0\",")
        lines.append("  \"app\": \">=1.0.0 <2.0.0\",")
        lines.append("  \"runtime\": \"\(runtime)\",")
        if let entry { lines.append("  \"entry\": \"\(entry)\",") }
        lines.append("  \"license\": \"MIT\",")
        if spec.permissions.isEmpty { lines.append("  \"permissions\": [],") }
        else {
            lines.append("  \"permissions\": [")
            lines.append(spec.permissions.map { "    \($0)" }.joined(separator: ",\n"))
            lines.append("  ],")
        }
        lines.append("  \"contributes\": {")
        let keys = contributionOrder.filter { spec.contributes[$0] != nil }
        lines.append(keys.map { "    \"\($0)\": \(spec.contributes[$0]!)" }.joined(separator: ",\n"))
        lines.append("  },")
        if spec.hooks.isEmpty { lines.append("  \"hooks\": [],") }
        else {
            lines.append("  \"hooks\": [")
            lines.append(spec.hooks.map { "    {\"name\": \"\($0.name)\", \"handler\": \"\($0.handler)\", \"version\": 1}" }.joined(separator: ",\n"))
            lines.append("  ],")
        }
        lines.append("  \"settings\": [],")
        lines.append("  \"dependencies\": [],")
        lines.append("  \"conflicts\": []")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    static func templateSpec(_ template: ScaffoldTemplate, language: ScaffoldLanguage?, name: String, id: String) -> Spec {
        var spec = Spec()
        switch template {
        case .column:
            spec.permissions = [
                "{\"kind\": \"fs.read\", \"scope\": \"selection\", \"recursive\": false, \"reason\": \"Read the headers of the images you select\"}",
                "{\"kind\": \"ui\", \"surfaces\": [\"column\"]}",
            ]
            spec.contributes["columns"] = "[{\"id\": \"dimensions\", \"title\": \"Dimensions\", \"valueType\": \"string\", \"handler\": \"columnValues\"}]"
            spec.hooks = [("column.values", "columnValues")]
            switch language {
            case .bfscript:
                spec.script = """
                {
                  "format": 1,
                  "functions": {
                    "columnValues": {
                      "signature": "column.values@1",
                      "body": [
                        {"return": {"await": {"call": "media.imageDimensions", "args": [{"get": ["input", "items"]}]}}}
                      ]
                    }
                  }
                }

                """
            case .ts:
                spec.script = """
                import { media } from "betterfinder";
                import type { ColumnValuesHandler } from "betterfinder";

                export const columnValues: ColumnValuesHandler = async (context, input) => {
                  return await media.imageDimensions(input.items);
                };

                """
            case .js:
                spec.script = """
                import { media } from "betterfinder";

                /** @type {import("betterfinder").ColumnValuesHandler} */
                export const columnValues = async (context, input) => {
                  return await media.imageDimensions(input.items);
                };

                """
            case nil: break
            }
        case .sidebar:
            spec.permissions = ["{\"kind\": \"ui\", \"surfaces\": [\"sidebar\"]}"]
            spec.contributes["sidebarSections"] = """
            [{"id": "favorites", "title": "Favorites", "items": [
                  {"id": "downloads", "title": "Downloads", "knownFolder": "downloads", "icon": "arrow.down.circle"},
                  {"id": "documents", "title": "Documents", "knownFolder": "documents", "icon": "doc"}
                ]}]
            """
        case .toolbar:
            spec.permissions = ["{\"kind\": \"ui\", \"surfaces\": [\"toolbar\"]}"]
            spec.contributes["commands"] = "[{\"id\": \"say-hello\", \"title\": \"Say Hello\", \"handler\": \"sayHello\"}]"
            spec.contributes["toolbar"] = "[{\"id\": \"hello\", \"title\": \"Hello\", \"command\": \"say-hello\", \"icon\": \"hand.wave\"}]"
            spec.hooks = [("command.run", "sayHello")]
            switch language {
            case .bfscript:
                spec.script = """
                {
                  "format": 1,
                  "functions": {
                    "sayHello": {
                      "signature": "command.run@1",
                      "body": [
                        {"return": {"record": {"message": "Hello from \(name)"}}}
                      ]
                    }
                  }
                }

                """
            case .ts:
                spec.script = """
                import type { CommandRunHandler } from "betterfinder";

                export const sayHello: CommandRunHandler = async (context, input) => {
                  return { message: "Hello from \(name)" };
                };

                """
            case .js:
                spec.script = """
                /** @type {import("betterfinder").CommandRunHandler} */
                export const sayHello = async (context, input) => {
                  return { message: "Hello from \(name)" };
                };

                """
            case nil: break
            }
        case .panel:
            spec.permissions = ["{\"kind\": \"ui\", \"surfaces\": [\"panel\"]}"]
            spec.contributes["panels"] = "[{\"id\": \"notes\", \"title\": \"\(name)\", \"edge\": \"right\", \"presentation\": \"slideOut\", \"icon\": \"sidebar.right\"}]"
            spec.hooks = [("activate", "activate")]
            switch language {
            case .bfscript:
                spec.script = """
                {
                  "format": 1,
                  "functions": {
                    "activate": {
                      "signature": "activate@1",
                      "body": [
                        {"do": {"await": {"call": "ui.setPanel", "args": [
                          "notes",
                          {"record": {"type": "vstack", "children": {"list": [
                            {"record": {"type": "text", "text": "Hello from \(name)", "label": "Greeting"}}
                          ]}}}
                        ]}}},
                        {"return": null}
                      ]
                    }
                  }
                }

                """
            case .ts:
                spec.script = """
                import { ui } from "betterfinder";
                import type { ActivateHandler } from "betterfinder";

                export const activate: ActivateHandler = async (context, input) => {
                  await ui.setPanel("notes", {
                    type: "vstack",
                    children: [{ type: "text", text: "Hello from \(name)", label: "Greeting" }],
                  });
                };

                """
            case .js:
                spec.script = """
                import { ui } from "betterfinder";

                /** @type {import("betterfinder").ActivateHandler} */
                export const activate = async (context, input) => {
                  await ui.setPanel("notes", {
                    type: "vstack",
                    children: [{ type: "text", text: "Hello from \(name)", label: "Greeting" }],
                  });
                };

                """
            case nil: break
            }
        case .preview:
            spec.permissions = [
                "{\"kind\": \"fs.read\", \"scope\": \"selection\", \"recursive\": false, \"reason\": \"Read the text file being previewed\"}",
                "{\"kind\": \"ui\", \"surfaces\": [\"preview\"]}",
            ]
            spec.contributes["previews"] = "[{\"id\": \"text\", \"title\": \"Text\", \"extensions\": [\"txt\", \"log\"], \"handler\": \"renderPreview\"}]"
            spec.hooks = [("preview.render", "renderPreview")]
            switch language {
            case .bfscript:
                spec.script = """
                {
                  "format": 1,
                  "functions": {
                    "renderPreview": {
                      "signature": "preview.render@1",
                      "body": [
                        {"let": "text", "value": {"await": {"call": "fs.readText", "args": [{"get": ["input", "item"]}, {"get": ["input", "maxBytes"]}]}}},
                        {"return": {"record": {
                          "title": {"get": ["input", "item", "name"]},
                          "node": {"record": {"type": "text", "text": {"get": ["text"]}}}
                        }}}
                      ]
                    }
                  }
                }

                """
            case .ts:
                spec.script = """
                import { fs } from "betterfinder";
                import type { PreviewRenderHandler } from "betterfinder";

                export const renderPreview: PreviewRenderHandler = async (context, input) => {
                  const text = await fs.readText(input.item, input.maxBytes);
                  return { title: input.item.name, node: { type: "text", text } };
                };

                """
            case .js:
                spec.script = """
                import { fs } from "betterfinder";

                /** @type {import("betterfinder").PreviewRenderHandler} */
                export const renderPreview = async (context, input) => {
                  const text = await fs.readText(input.item, input.maxBytes);
                  return { title: input.item.name, node: { type: "text", text } };
                };

                """
            case nil: break
            }
        case .command:
            spec.contributes["commands"] = "[{\"id\": \"count-selection\", \"title\": \"Count Selection\", \"handler\": \"countSelection\", \"category\": \"Selection\"}]"
            spec.hooks = [("command.run", "countSelection")]
            switch language {
            case .bfscript:
                spec.script = """
                {
                  "format": 1,
                  "functions": {
                    "countSelection": {
                      "signature": "command.run@1",
                      "body": [
                        {"return": {"record": {
                          "message": {"concat": ["Selected ", {"toString": {"length": {"get": ["input", "selection"]}}}, " items"]}
                        }}}
                      ]
                    }
                  }
                }

                """
            case .ts:
                spec.script = """
                import type { CommandRunHandler } from "betterfinder";

                export const countSelection: CommandRunHandler = async (context, input) => {
                  return { message: `Selected ${input.selection.length} items` };
                };

                """
            case .js:
                spec.script = """
                /** @type {import("betterfinder").CommandRunHandler} */
                export const countSelection = async (context, input) => {
                  return { message: `Selected ${input.selection.length} items` };
                };

                """
            case nil: break
            }
        case .theme:
            let local = id.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? id
            spec.contributes["themes"] = "[{\"id\": \"\(local)\", \"title\": \"\(name)\", \"path\": \"themes/\(local).json\", \"appearance\": \"dark\"}]"
            spec.extraFiles = [ScaffoldFile(path: "themes/\(local).json", contents: themeJSON(id: local, name: name))]
        }
        return spec
    }

    static func themeJSON(id: String, name: String) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name)",
          "base": "dark",
          "colors": {
            "windowBg": "system:windowBackground",
            "listBg": "system:controlBackground",
            "rowAlt": "system:alternateRow",
            "selection": "system:selection",
            "selectionText": "system:selectionText",
            "text": "system:text",
            "secondaryText": "system:secondaryText",
            "sidebarBg": "system:clear",
            "sidebarText": "system:text",
            "statusBarBg": "system:windowBackground",
            "statusBarText": "system:secondaryText",
            "toolbarBg": "system:windowBackground",
            "accent": "system:accent",
            "border": "system:separator",
            "inactiveSelection": "system:inactiveSelection",
            "inactiveSelectionText": "system:text",
            "sidebarSelection": "system:selection",
            "sidebarSelectionText": "system:selectionText",
            "toolbarText": "system:text",
            "sidebarIcon": "system:accent"
          },
          "fonts": {
            "list": {"family": "system", "size": 13},
            "ui": {"family": "system", "size": 11}
          },
          "metrics": {
            "rowHeight": 22,
            "cornerRadius": 6,
            "bevel": "none",
            "borderWidth": 0,
            "statusBarHeight": 24
          },
          "chrome": {
            "titlebar": "native",
            "toolbarStyle": "native",
            "scrollbar": "native",
            "useNativeChrome": true
          },
          "icons": {"set": "system"},
          "sounds": {}
        }

        """
    }

    static let tsconfig = """
    {
      "compilerOptions": {
        "target": "ES2020",
        "module": "ES2020",
        "moduleResolution": "Bundler",
        "strict": true,
        "noImplicitAny": true,
        "isolatedModules": true,
        "allowJs": true,
        "checkJs": true,
        "noEmit": true,
        "lib": ["ES2020"],
        "types": []
      },
      "include": ["scripts", "betterfinder.d.ts"]
    }

    """

    static func license(author: String) -> String {
        """
        MIT License

        Copyright (c) \(author)

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

        """
    }

    static func readme(id: String, name: String, language: ScaffoldLanguage?, template: ScaffoldTemplate) -> String {
        let lang: String
        switch language {
        case .bfscript: lang = "typed JSON (`scripts/main.bfscript.json`)"
        case .ts: lang = "TypeScript (`scripts/main.ts`)"
        case .js: lang = "JavaScript (`scripts/main.js`)"
        case nil: lang = "data only (no script)"
        }
        return """
        # \(name)

        `\(id)` is a betterfinder mod generated from the `\(template.rawValue)` template, written as \(lang).

        ```sh
        betterfinder-mod validate .
        betterfinder-mod package . --out \(id).bfmod
        ```

        Edit `manifest.json` to change permissions and contributions. Every catalog call a script makes needs a matching permission, and `validate` reports undeclared and unused ones.

        """
    }
}
