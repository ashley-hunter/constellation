import AppKit
import ConstellationCore
import SwiftUI

/// A parsed diff ready to show: the rows for side by side and the widths it needs, worked out
/// once off the main thread rather than on every redraw.
struct DiffDisplay: Sendable {
    let diff: UnifiedDiff
    let text: String
    /// Side-by-side rows, by file then hunk.
    let rows: [[[DiffRow]]]
    /// In characters, with tabs expanded.
    let longestLine: Int
    let numberDigits: Int

    init(_ text: String) {
        self.text = text
        diff = UnifiedDiff(parsing: text)
        rows = diff.files.map { $0.hunks.map(\.rows) }
        let lines = diff.files.lazy.flatMap(\.hunks).flatMap(\.lines)
        longestLine = lines.map { DiffText.display($0.text[...]).count }.max() ?? 0
        let largest = diff.files.lazy.flatMap(\.hunks).map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 0
        numberDigits = max(2, String(largest).count)
    }
}

/// The Diff tab: a summary, then each file as a section that folds, its hunks under quiet
/// separators. Old and new line numbers sit in the gutter, and the words that changed within a
/// line are picked out. Lines never wrap: the pane scrolls sideways while headers and gutters stay
/// put. Wide enough, old and new go side by side.
struct DiffView: View {
    static let splitWidth: CGFloat = 900
    /// Past this many lines only the first few files start open.
    static let bigDiff = 400
    static let openWhenBig = 3

    let display: DiffDisplay
    /// Relative to the worktree, for the dot on the file the agent touched last.
    let lastWrittenPath: String?
    /// Files folded or unfolded by hand, by path, so a refresh keeps them as they were.
    @State private var isOpen: [String: Bool] = [:]
    @State private var scroll = DiffScroll()

    private var diff: UnifiedDiff { display.diff }

    private static var scrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    var body: some View {
        GeometryReader { proxy in
            // Scroll bars that are always shown sit over the content, so leave them room.
            let width = (scroll.width ?? proxy.size.width) - Self.scrollerWidth
            let metrics = DiffMetrics(display: display, viewport: width, isSplit: width >= Self.splitWidth)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items(isSplit: metrics.isSplit)) { item in
                        view(for: item, metrics: metrics)
                    }
                }
                .font(.mono(12))
                .textSelection(.enabled)
                .padding(.bottom, 16)
                .frame(width: metrics.contentWidth, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .onScrollGeometryChange(for: CGPoint.self) {
                CGPoint(x: $0.contentOffset.x, y: $0.visibleRect.width)
            } action: { _, geometry in
                if scroll.x != geometry.x { scroll.x = geometry.x }
                if scroll.width != geometry.y { scroll.width = geometry.y }
            }
            .environment(scroll)
        }
        .copyable(display.text, help: "Copy diff")
    }

    // MARK: Items

    private enum Item: Hashable, Identifiable {
        case summary
        case file(Int)
        case hunk(Int, Int)
        /// File, hunk, and line in unified or row in side by side.
        case line(Int, Int, Int)
        case row(Int, Int, Int)
        case note(Int)

        var id: Self { self }
    }

    /// The diff flattened, so one lazy stack covers every file and only what's on screen is built.
    private func items(isSplit: Bool) -> [Item] {
        var items: [Item] = [.summary]
        for (fileIndex, file) in diff.files.enumerated() {
            items.append(.file(fileIndex))
            guard opens(fileIndex) else { continue }
            if file.status == .binary || file.hunks.isEmpty {
                items.append(.note(fileIndex))
                continue
            }
            for (hunkIndex, hunk) in file.hunks.enumerated() {
                items.append(.hunk(fileIndex, hunkIndex))
                let count = isSplit ? display.rows[fileIndex][hunkIndex].count : hunk.lines.count
                for index in 0..<count {
                    items.append(isSplit ? .row(fileIndex, hunkIndex, index) : .line(fileIndex, hunkIndex, index))
                }
            }
        }
        return items
    }

    private func opens(_ index: Int) -> Bool {
        isOpen[diff.files[index].path] ?? (diff.lineCount <= Self.bigDiff || index < Self.openWhenBig)
    }

    @ViewBuilder private func view(for item: Item, metrics: DiffMetrics) -> some View {
        switch item {
        case .summary:
            DiffSummary(diff: diff)
                .frame(width: metrics.viewport, alignment: .leading)
                .pinnedLeading()
        case .file(let index):
            let file = diff.files[index]
            DiffFileHeader(file: file, isOpen: opens(index), isFirst: index == 0, isLastWritten: isLastWritten(file)) {
                isOpen[file.path] = !opens(index)
            }
            .frame(width: metrics.viewport)
            .pinnedLeading()
        case .hunk(let file, let hunk):
            DiffHunkHeader(hunk: diff.files[file].hunks[hunk], inset: metrics.isSplit ? 16 : metrics.unifiedGutter + 8)
                .frame(width: metrics.viewport, alignment: .leading)
                .pinnedLeading()
        case .line(let file, let hunk, let index):
            UnifiedDiffRow(line: diff.files[file].hunks[hunk].lines[index], metrics: metrics)
        case .row(let file, let hunk, let index):
            let lines = diff.files[file].hunks[hunk].lines
            let row = display.rows[file][hunk][index]
            HStack(spacing: 0) {
                SplitDiffCell(line: row.old.map { lines[$0] }, side: .old, metrics: metrics)
                Palette.hairline.frame(width: 1)
                SplitDiffCell(line: row.new.map { lines[$0] }, side: .new, metrics: metrics)
            }
            .frame(width: metrics.viewport, alignment: .leading)
            .pinnedLeading()
        case .note(let index):
            Text(note(for: diff.files[index]))
                .font(.ui(12))
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 36)
                .padding(.vertical, 10)
                .frame(width: metrics.viewport, alignment: .leading)
                .pinnedLeading()
        }
    }

    private func note(for file: FileDiff) -> String {
        if file.status == .binary { return "Binary file" }
        return file.status == .renamed ? "Renamed without changes" : "No changes to the contents"
    }

    private func isLastWritten(_ file: FileDiff) -> Bool {
        guard let lastWrittenPath else { return false }
        return file.newPath == lastWrittenPath || (file.newPath == nil && file.oldPath == lastWrittenPath)
    }
}

/// Widths for one layout of the diff. Every line row is as wide as the longest line, so the
/// sideways scroll stays put as rows come and go.
struct DiffMetrics {
    static let characterWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ceil(("0" as NSString).size(withAttributes: [.font: font]).width * 100) / 100
    }()
    static let edge: CGFloat = 2
    static let marker: CGFloat = 20

    let viewport: CGFloat
    let isSplit: Bool
    let numberWidth: CGFloat
    let textWidth: CGFloat

    init(display: DiffDisplay, viewport: CGFloat, isSplit: Bool) {
        self.viewport = viewport
        self.isSplit = isSplit
        numberWidth = CGFloat(display.numberDigits) * Self.characterWidth + 16
        textWidth = CGFloat(display.longestLine) * Self.characterWidth + 32
    }

    /// Both number columns, the coloured edge and the + or - beside it.
    var unifiedGutter: CGFloat { Self.edge + numberWidth * 2 + Self.marker }

    /// One side of the side-by-side view: always half the pane.
    var column: CGFloat { (viewport - 1) / 2 }

    /// How far the longest line runs past its column side by side. The pane scrolls this far and
    /// both sides' text moves with it, inside their columns.
    var splitOverflow: CGFloat { max(0, textWidth - (column - Self.edge - numberWidth - Self.marker)) }

    var contentWidth: CGFloat {
        isSplit ? viewport + splitOverflow : max(viewport, unifiedGutter + textWidth)
    }
}

/// Where the diff has scrolled to sideways, and how wide the pane shows. Only the side-by-side
/// text reads `x`, so scrolling redraws just those.
@Observable final class DiffScroll {
    var x: CGFloat = 0
    var width: CGFloat?
}

// MARK: Headers

private struct DiffSummary: View {
    let diff: UnifiedDiff

    var body: some View {
        HStack(spacing: 8) {
            Text(diff.files.count == 1 ? "1 file" : "\(diff.files.count) files")
                .foregroundStyle(Palette.textSecondary)
            DiffCounts(additions: diff.additions, deletions: diff.deletions)
            DiffStatBar(additions: diff.additions, deletions: diff.deletions)
        }
        .font(.ui(12)).monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diff.files.count) files changed, \(diff.additions) lines added, \(diff.deletions) removed")
    }
}

private struct DiffCounts: View {
    let additions: Int
    let deletions: Int
    /// A file's header leaves out a side with nothing on it, such as the removals of a new file.
    var showsZero = true

    var body: some View {
        HStack(spacing: 6) {
            if showsZero || additions > 0 { Text("+\(additions)").foregroundStyle(Palette.done) }
            if showsZero || deletions > 0 { Text("\u{2212}\(deletions)").foregroundStyle(Palette.error) }
        }
        .monospacedDigit()
    }
}

/// Five blocks shared between green and red in proportion, as GitHub draws it.
private struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < green ? Palette.done : index < green + red ? Palette.error : Palette.text.opacity(0.12))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var total: Int { additions + deletions }

    private var green: Int {
        guard total > 0 else { return 0 }
        let share = Int((5 * Double(additions) / Double(total)).rounded())
        return min(deletions > 0 ? 4 : 5, max(additions > 0 ? 1 : 0, share))
    }

    private var red: Int { total > 0 ? 5 - green : 0 }
}

private struct DiffFileHeader: View {
    let file: FileDiff
    let isOpen: Bool
    let isFirst: Bool
    let isLastWritten: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                path
                if let badge {
                    Text(badge)
                        .font(.ui(11))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Palette.text.opacity(0.08), in: .capsule)
                }
                if isLastWritten {
                    Circle().fill(Palette.focus).frame(width: 6, height: 6)
                        .help("The file the agent wrote last")
                }
                Spacer(minLength: 12)
                if file.status != .binary {
                    DiffCounts(additions: file.additions, deletions: file.deletions, showsZero: false).font(.ui(12))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(isHovered ? Palette.rowHover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !isFirst { Palette.hairline.frame(height: 1) }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
    }

    private var path: some View {
        let path = file.status == .renamed ? file.newPath ?? file.path : file.path
        let slash = path.lastIndex(of: "/")
        let directory = slash.map { String(path[...$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        let renamedFrom = file.status == .renamed ? file.oldPath.map { "\($0) \u{2192} " } ?? "" : ""
        let muted = Text("\(renamedFrom)\(directory)").foregroundStyle(Palette.textTertiary)
        return Text("\(muted)\(Text(name).foregroundStyle(Palette.text))")
            .font(.ui(13))
            .lineLimit(1)
            .truncationMode(.head)
    }

    private var badge: String? {
        switch file.status {
        case .added: "new"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .binary: "binary"
        case .modified: nil
        }
    }

    private var accessibilityLabel: String {
        var parts = [file.path]
        if let badge { parts.append(badge) }
        if file.status != .binary { parts.append("\(file.additions) added, \(file.deletions) removed") }
        if isLastWritten { parts.append("written last") }
        return parts.joined(separator: ", ")
    }
}

/// A quiet separator between hunks, naming the function git found or the lines it covers.
private struct DiffHunkHeader: View {
    let hunk: DiffHunk
    let inset: CGFloat

    var body: some View {
        Text(label)
            .font(.mono(11))
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .padding(.leading, inset)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.text.opacity(0.03))
    }

    private var label: String {
        if let context = hunk.context { return context }
        let (start, count) = hunk.newCount > 0 ? (hunk.newStart, hunk.newCount) : (hunk.oldStart, hunk.oldCount)
        return count <= 1 ? "Line \(start)" : "Lines \(start)\u{2013}\(start + count - 1)"
    }
}

// MARK: Lines

private struct UnifiedDiffRow: View {
    let line: DiffLine
    let metrics: DiffMetrics

    var body: some View {
        ZStack(alignment: .leading) {
            DiffText(line: line)
                .padding(.leading, metrics.unifiedGutter)
            // The gutter stays at the left edge when the lines scroll sideways, so it covers them.
            HStack(spacing: 0) {
                DiffEdge(kind: line.kind)
                DiffNumber(number: line.oldNumber, width: metrics.numberWidth)
                DiffNumber(number: line.newNumber, width: metrics.numberWidth)
                DiffMarker(kind: line.kind)
            }
            .background(Palette.surfaceSunken)
            .background(line.kind.tint)
            .pinnedLeading()
        }
        .frame(width: metrics.contentWidth, alignment: .leading)
        .background(line.kind.tint)
        .diffLineAccessibility(line)
    }
}

private struct SplitDiffCell: View {
    enum Side { case old, new }

    let line: DiffLine?
    let side: Side
    let metrics: DiffMetrics

    var body: some View {
        Group {
            if let line {
                HStack(spacing: 0) {
                    DiffEdge(kind: line.kind)
                    DiffNumber(number: side == .old ? line.oldNumber : line.newNumber, width: metrics.numberWidth)
                    DiffMarker(kind: line.kind)
                    SplitScrolledText(line: line, overflow: metrics.splitOverflow)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .clipped()
                }
                .background(line.kind.tint)
                .diffLineAccessibility(line)
            } else {
                // Nothing on this side to pair with: a blank the height of a line.
                Text(" ").frame(maxWidth: .infinity).background(Palette.text.opacity(0.02))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: metrics.column, alignment: .leading)
    }
}

/// Side by side the rows stay in place and only the text inside each column moves, so both
/// sides scroll together and neither pushes the other out of view.
private struct SplitScrolledText: View {
    @Environment(DiffScroll.self) private var scroll
    let line: DiffLine
    let overflow: CGFloat

    var body: some View {
        DiffText(line: line)
            .offset(x: -min(max(0, scroll.x), overflow))
    }
}

private struct DiffEdge: View {
    let kind: DiffLine.Kind

    var body: some View {
        Rectangle().fill(kind.edge).frame(width: DiffMetrics.edge)
    }
}

private struct DiffNumber: View {
    let number: Int?
    let width: CGFloat

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(.mono(11))
            .foregroundStyle(Palette.textTertiary.opacity(0.7))
            .frame(width: width - 8, alignment: .trailing)
            .padding(.trailing, 8)
            .textSelection(.disabled)
    }
}

private struct DiffMarker: View {
    let kind: DiffLine.Kind

    var body: some View {
        Text(kind == .added ? "+" : kind == .removed ? "\u{2212}" : "")
            .foregroundStyle(kind.edge)
            .frame(width: DiffMetrics.marker, alignment: .leading)
            .textSelection(.disabled)
    }
}

/// One line's text with the changed words picked out, and a note where the file has no newline.
struct DiffText: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 8) {
            Text(attributed)
                .foregroundStyle(line.kind == .context ? Palette.textSecondary : Palette.text)
                .lineLimit(1)
                .fixedSize()
            if line.missingNewline {
                Text("No newline at end of file")
                    .font(.ui(11))
                    .foregroundStyle(Palette.textTertiary)
                    .textSelection(.disabled)
            }
        }
        .padding(.vertical, 1.5)
        .padding(.trailing, 16)
    }

    private var attributed: AttributedString {
        let characters = Array(line.text)
        guard !characters.isEmpty else { return AttributedString(" ") }
        var result = AttributedString()
        var cursor = 0
        for change in line.changes {
            let range = min(change.lowerBound, characters.count)..<min(change.upperBound, characters.count)
            guard range.lowerBound >= cursor, !range.isEmpty else { continue }
            if cursor < range.lowerBound { result += AttributedString(Self.display(characters[cursor..<range.lowerBound])) }
            var changed = AttributedString(Self.display(characters[range]))
            changed.backgroundColor = line.kind.wordTint
            result += changed
            cursor = range.upperBound
        }
        if cursor < characters.count { result += AttributedString(Self.display(characters[cursor...])) }
        return result
    }

    /// Tabs as four spaces, so widths in characters hold.
    nonisolated static func display(_ characters: some Collection<Character>) -> String {
        String(characters).replacing("\t", with: "    ")
    }
}

private extension DiffLine.Kind {
    var edge: Color {
        switch self {
        case .added: Palette.done
        case .removed: Palette.error
        case .context: .clear
        }
    }

    var tint: Color {
        switch self {
        case .added: Palette.done.opacity(0.08)
        case .removed: Palette.error.opacity(0.1)
        case .context: .clear
        }
    }

    var wordTint: Color {
        switch self {
        case .added: Palette.done.opacity(0.3)
        case .removed: Palette.error.opacity(0.32)
        case .context: .clear
        }
    }
}

private extension View {
    /// Keeps a view at the left edge of the pane while the lines under it scroll sideways.
    func pinnedLeading() -> some View {
        visualEffect { content, proxy in
            content.offset(x: max(0, -proxy.frame(in: .scrollView).minX))
        }
    }

    func diffLineAccessibility(_ line: DiffLine) -> some View {
        let kind = switch line.kind {
        case .added: "Added line \(line.newNumber ?? 0)"
        case .removed: "Removed line \(line.oldNumber ?? 0)"
        case .context: "Line \(line.newNumber ?? 0)"
        }
        return accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind): \(line.text)")
    }
}
