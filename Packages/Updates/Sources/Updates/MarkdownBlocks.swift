import Foundation

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case numbered(number: String, text: String)
    case code(String)
    case paragraph(String)
    case rule
}

public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let existing = code {
                    blocks.append(.code(existing.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) || trimmed.allSatisfy({ $0 == "*" }) || trimmed.allSatisfy({ $0 == "_" }) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let rest = trimmed.dropFirst(hashes.count)
                if hashes.count <= 6, rest.first == " " {
                    flushParagraph()
                    blocks.append(.heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if let bullet = bulletItem(raw) {
                flushParagraph()
                blocks.append(bullet)
                continue
            }
            if let numbered = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(numbered)
                continue
            }
            paragraph.append(trimmed)
        }
        if let existing = code { blocks.append(.code(existing.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func bulletItem(_ raw: String) -> MarkdownBlock? {
        let leading = raw.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = raw.dropFirst(leading.count)
        guard let marker = rest.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        return .bullet(indent: indent, text: after.trimmingCharacters(in: .whitespaces))
    }

    private static func numberedItem(_ trimmed: String) -> MarkdownBlock? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return .numbered(number: String(digits), text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
