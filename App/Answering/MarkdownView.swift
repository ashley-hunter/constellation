import SwiftUI

/// Renders the block markdown agents write in plans and docs: headings, lists, code fences and
/// paragraphs, with inline emphasis, code and links.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.ui(level == 1 ? 20 : level == 2 ? 16 : 14, weight: .medium))
                .foregroundStyle(Palette.text)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.ui(14))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.ui(12)).foregroundStyle(Palette.textTertiary)
                Text(Self.inline(text))
                    .font(.ui(14))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .code(let text):
            CodeBlock(text, maxHeight: 220)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        var string = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = .mono(13)
            string[run.range].foregroundColor = Palette.text
        }
        for run in string.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            string[run.range].foregroundColor = Palette.text
        }
        return string
    }
}

enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, depth: Int, text: String)
    case code(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var fence: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let code = fence {
                    blocks.append(.code(code.joined(separator: "\n")))
                    fence = nil
                } else {
                    flushParagraph()
                    fence = []
                }
                continue
            }
            if fence != nil {
                fence?.append(raw)
                continue
            }
            if line.isEmpty {
                flushParagraph()
            } else if let heading = heading(line) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = listItem(raw) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(line)
            }
        }
        if let code = fence { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ raw: String) -> MarkdownBlock? {
        let indent = raw.prefix { $0 == " " }.count
        let line = raw.dropFirst(indent)
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            var text = String(line.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
            if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
            return .listItem(marker: marker, depth: indent / 2, text: text)
        }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return .listItem(marker: "\(digits).", depth: indent / 2, text: String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }
}
