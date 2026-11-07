import Browser
import Foundation
import ModHost

public struct ConvertedModUI: Sendable {
    public var node: Browser.ModUINode
    public var commands: [String: String]
    public var markdown: String?
    public var fields: [String: String] = [:]
    public var fieldValues: [String: String] = [:]
    public var duplicateIDs: [String] = []

    public var issues: [String] {
        node.accessibilityIssues().map { $0.hasPrefix("id:") ? String($0.dropFirst(3)) : $0 }
    }

    public var warnings: [String] {
        duplicateIDs.map { "\($0): id is used by more than one node" }
    }
}

public enum ModUIConversion {
    public static func markdownText(_ source: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return source }
        return String(parsed.characters)
    }

    public static func convert(_ node: ModHost.ModUINode, commandResolver: (ModCommandReference) -> String) -> ConvertedModUI {
        var state = State()
        let out = convert(node, path: "n", state: &state, resolve: commandResolver)
        return ConvertedModUI(
            node: out, commands: state.commands, markdown: node.kind == .markdown ? node.text : nil, fields: state.fieldIDs, fieldValues: state.fieldValues,
            duplicateIDs: state.duplicates.sorted()
        )
    }

    public static func stableID(_ authorID: String) -> String { "id:\(authorID)" }

    struct State {
        var commands: [String: String] = [:]
        var fieldIDs: [String: String] = [:]
        var fieldValues: [String: String] = [:]
        var authorIDs: Set<String> = []
        var duplicates: Set<String> = []
    }

    private static func nonBlank(_ s: String?) -> String? { ModHost.ModUINode.normalizedLabel(s) }

    private static func convert(_ n: ModHost.ModUINode, path: String, state: inout State, resolve: (ModCommandReference) -> String) -> Browser.ModUINode {
        let id: String
        if let author = n.id, !author.isEmpty {
            if state.authorIDs.insert(author).inserted {
                id = stableID(author)
            } else {
                state.duplicates.insert(author)
                id = "\(path).\(author)"
            }
        } else {
            id = path
        }
        let label = nonBlank(n.accessibilityLabel)
        switch n.kind {
        case .vstack, .hstack:
            let children = n.children.enumerated().map { convert($1, path: "\(path).\($0)", state: &state, resolve: resolve) }
            return Browser.ModUINode(id: id, kind: .stack(axis: n.kind == .vstack ? .vertical : .horizontal, spacing: nil, children: children), accessibilityLabel: label)
        case .text:
            return Browser.ModUINode(id: id, kind: .label(text: n.text ?? "", style: .body), accessibilityLabel: label)
        case .markdown:
            return Browser.ModUINode(id: id, kind: .label(text: markdownText(n.text ?? ""), style: .body), accessibilityLabel: label)
        case .button:
            if let c = n.command { state.commands[id] = resolve(c) }
            return Browser.ModUINode(id: id, kind: .button(title: n.text ?? "", symbolName: nil), accessibilityLabel: label ?? nonBlank(n.text), isEnabled: n.command != nil)
        case .list:
            let items = n.items.map { Browser.ModUIListItem(id: $0.id, title: $0.title, subtitle: $0.subtitle) }
            return Browser.ModUINode(id: id, kind: .list(items: items, selectedID: nil), accessibilityLabel: label ?? nonBlank(n.text))
        case .progress:
            let value = n.value.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
            return Browser.ModUINode(id: id, kind: .progress(value: value, caption: n.text), accessibilityLabel: label ?? nonBlank(n.text) ?? "Progress")
        case .divider:
            return Browser.ModUINode(id: id, kind: .separator, accessibilityLabel: label)
        case .textField:
            if let c = n.command { state.commands[id] = resolve(c) }
            let value = String((n.text ?? "").prefix(4096))
            state.fieldIDs[id] = n.id ?? id
            state.fieldValues[id] = value
            return Browser.ModUINode.textField(id: id, value: value, placeholder: n.placeholder, accessibilityLabel: label ?? nonBlank(n.placeholder))
        }
    }
}
