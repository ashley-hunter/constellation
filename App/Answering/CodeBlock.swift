import SwiftUI

/// Mono text with line numbers. Lines starting with + or - are tinted as a diff.
struct CodeBlock: View {
    let text: String
    var maxHeight: CGFloat = 280
    /// Treat leading + and - as diff markers. Off for plain commands and file contents.
    var isDiff: Bool
    /// Off when the block fills a pane of its own, which is frame enough.
    var isFramed = true

    init(_ text: String, isDiff: Bool? = nil, maxHeight: CGFloat = 280, isFramed: Bool = true) {
        self.text = text
        self.maxHeight = maxHeight
        self.isFramed = isFramed
        self.isDiff = isDiff ?? Self.looksLikeDiff(text)
    }

    private var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        let lines = lines
        let gutter = CGFloat(max(2, String(lines.count).count)) * 8 + 12
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(index + 1)")
                            .foregroundStyle(Color(hex: 0x6E695F))
                            .frame(width: gutter, alignment: .trailing)
                            .padding(.trailing, 12)
                        Text(line.isEmpty ? " " : String(line))
                            .foregroundStyle(color(of: line))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.trailing, 12)
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(of: line))
                }
            }
            .font(.mono(12))
            .textSelection(.enabled)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: maxHeight.isInfinite ? false : true)
        .background(isFramed ? Palette.surfaceSunken : .clear, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.text.opacity(isFramed ? 0.06 : 0)))
        .copyable(text, help: isDiff ? "Copy diff" : "Copy code")
    }

    private func color(of line: Substring) -> Color {
        guard isDiff else { return Palette.text }
        if line.hasPrefix("@@") { return Palette.working }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return Palette.textTertiary
        }
        if line.hasPrefix("+") { return Palette.done }
        if line.hasPrefix("-") { return Palette.error }
        return Palette.textSecondary
    }

    private func background(of line: Substring) -> Color {
        guard isDiff, !line.hasPrefix("+++"), !line.hasPrefix("---") else { return .clear }
        if line.hasPrefix("+") { return Palette.done.opacity(0.08) }
        if line.hasPrefix("-") { return Palette.error.opacity(0.1) }
        return .clear
    }

    static func looksLikeDiff(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix(" ") || $0.hasPrefix("@@") || $0.hasPrefix("diff ") || $0.hasPrefix("index ") }
            && lines.contains { $0.hasPrefix("+") || $0.hasPrefix("-") }
    }
}
