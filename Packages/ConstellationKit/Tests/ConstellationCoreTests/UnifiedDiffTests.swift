import Testing
@testable import ConstellationCore

@Suite struct UnifiedDiffTests {
    /// A real `git diff` of a worktree: an edit, a new file, and a function changed in two places.
    static let edits = """
    diff --git a/src/format.ts b/src/format.ts
    index 1ab96cf..8d442c7 100644
    --- a/src/format.ts
    +++ b/src/format.ts
    @@ -1 +1,2 @@
    -export const currency = (pence: number) => `£${(pence / 100).toFixed(2)}`
    +export const currency = (pounds: number) =>
    +  new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' }).format(pounds)
    diff --git a/src/vat.test.ts b/src/vat.test.ts
    new file mode 100644
    index 0000000..e673057
    --- /dev/null
    +++ b/src/vat.test.ts
    @@ -0,0 +1,5 @@
    +import { invoiceTotal } from './vat'
    +
    +test('rounds each line to the penny', () => {
    +  expect(invoiceTotal([{ net: 0.105, rate: 0.2 }, { net: 0.105, rate: 0.2 }])).toBe(0.26)
    +})
    diff --git a/src/vat.ts b/src/vat.ts
    index 36e5fc8..1faa17b 100644
    --- a/src/vat.ts
    +++ b/src/vat.ts
    @@ -1,7 +1,9 @@
     export function lineTotal(net: number, rate: number): number {
    -  return net * (1 + rate)
    +  // Round each line to the penny, so the invoice matches the receipts.
    +  return Math.round(net * (1 + rate) * 100) / 100
     }

     export function invoiceTotal(lines: { net: number; rate: number }[]): number {
    -  return lines.reduce((sum, line) => sum + lineTotal(line.net, line.rate), 0)
    +  const total = lines.reduce((sum, line) => sum + lineTotal(line.net, line.rate), 0)
    +  return Math.round(total * 100) / 100
     }

    """

    /// A deletion, a binary, a rename with an edit, and a file that gains its final newline.
    static let oddities = """
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    index 286c5f5..0000000
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    diff --git a/logo.png b/logo.png
    index 8352675..c5793f9 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git a/old.txt b/new.txt
    similarity index 74%
    rename from old.txt
    rename to new.txt
    index 7a28df3..600d48a 100644
    --- a/old.txt
    +++ b/new.txt
    @@ -2,3 +2,4 @@ alpha
     beta
     gamma
     delta
    +epsilon
    diff --git a/tail.txt b/tail.txt
    index 9ed40b4..4cb29ea 100644
    --- a/tail.txt
    +++ b/tail.txt
    @@ -1,2 +1,3 @@
     one
    -two
    \\ No newline at end of file
    +two
    +three

    """

    @Test func filesAndTotals() {
        let diff = UnifiedDiff(parsing: Self.edits)
        #expect(diff.files.map(\.path) == ["src/format.ts", "src/vat.test.ts", "src/vat.ts"])
        #expect(diff.files.map(\.status) == [.modified, .added, .modified])
        #expect(diff.files.map(\.additions) == [2, 5, 4])
        #expect(diff.files.map(\.deletions) == [1, 0, 2])
        #expect((diff.additions, diff.deletions) == (11, 3))
        #expect(diff.files[1].oldPath == nil)
    }

    @Test func linesAreNumberedOnEachSide() throws {
        let hunk = try #require(UnifiedDiff(parsing: Self.edits).files[2].hunks.first)
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (1, 7, 1, 9))
        #expect(hunk.context == nil)
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .added, .context, .context, .context, .removed, .added, .added, .context])
        #expect(hunk.lines.map(\.oldNumber) == [1, 2, nil, nil, 3, 4, 5, 6, nil, nil, 7])
        #expect(hunk.lines.map(\.newNumber) == [1, nil, 2, 3, 4, 5, 6, nil, 7, 8, 9])
        #expect(hunk.lines[0].text == "export function lineTotal(net: number, rate: number): number {")
        #expect(hunk.lines[5].text == "")
    }

    @Test func removedAndAddedRunsPairUpSideBySide() throws {
        let hunk = try #require(UnifiedDiff(parsing: Self.edits).files[2].hunks.first)
        #expect(hunk.rows == [
            DiffRow(old: 0, new: 0),
            DiffRow(old: 1, new: 2),
            DiffRow(old: nil, new: 3),
            DiffRow(old: 4, new: 4), DiffRow(old: 5, new: 5), DiffRow(old: 6, new: 6),
            DiffRow(old: 7, new: 8),
            DiffRow(old: nil, new: 9),
            DiffRow(old: 10, new: 10),
        ])
    }

    @Test func deletedBinaryAndRenamedFiles() {
        let files = UnifiedDiff(parsing: Self.oddities).files
        #expect(files.map(\.status) == [.deleted, .binary, .renamed, .modified])
        #expect((files[0].oldPath, files[0].newPath) == ("gone.txt", nil))
        #expect(files[0].hunks[0].lines.map(\.oldNumber) == [1])
        #expect(files[1].path == "logo.png")
        #expect(files[1].hunks.isEmpty)
        #expect((files[2].oldPath, files[2].newPath) == ("old.txt", "new.txt"))
        #expect(files[2].hunks[0].context == "alpha")
        #expect(files[2].hunks[0].lines.last?.newNumber == 5)
    }

    @Test func aMissingNewlineMarksTheLineBeforeIt() {
        let lines = UnifiedDiff(parsing: Self.oddities).files[3].hunks[0].lines
        #expect(lines.map(\.text) == ["one", "two", "two", "three"])
        #expect(lines.map(\.missingNewline) == [false, true, false, false])
    }

    @Test func aBinaryWithNoOtherHeaderTakesItsPathFromTheDiffLine() {
        let diff = UnifiedDiff(parsing: """
        diff --git a/assets/app icon.png b/assets/app icon.png
        new file mode 100644
        index 0000000..c5793f9
        Binary files /dev/null and b/assets/app icon.png differ
        """)
        #expect(diff.files.map(\.path) == ["assets/app icon.png"])
        #expect(diff.files.map(\.status) == [.binary])
    }

    @Test func quotedPathsAreUnescaped() {
        let diff = UnifiedDiff(parsing: """
        diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
        index 1..2 100644
        --- "a/caf\\303\\251.txt"
        +++ "b/caf\\303\\251.txt"
        @@ -1 +1 @@
        -a
        +b
        """)
        #expect(diff.files.map(\.path) == ["café.txt"])
    }

    @Test func aRemovedLineThatLooksLikeAHeaderStaysInTheHunk() {
        let diff = UnifiedDiff(parsing: """
        diff --git a/notes.md b/notes.md
        index 1..2 100644
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1 @@
        --- a rule
        -kept
        +kept
        """)
        let lines = diff.files[0].hunks[0].lines
        #expect(lines.map(\.kind) == [.removed, .removed, .added])
        #expect(lines[0].text == "-- a rule")
    }

    @Test func pairedLinesMarkTheWordsThatChanged() throws {
        let format = try #require(UnifiedDiff(parsing: Self.edits).files[2].hunks.first)
        let removed = format.lines[7], added = format.lines[8]
        #expect(removed.text.slices(removed.changes) == ["return"])
        #expect(added.text.slices(added.changes) == ["const total ="])
        // The unpaired added line has nothing to compare against.
        #expect(format.lines[9].changes.isEmpty)
        #expect(format.lines[0].changes.isEmpty)
    }

    @Test func wordChangesInTheMiddleOfALine() {
        let changes = WordDiff.changes("let total = price * rate", "let total = cost * rate + fee")
        #expect("let total = price * rate".slices(changes.old) == ["price"])
        #expect("let total = cost * rate + fee".slices(changes.new) == ["cost", "+ fee"])
    }

    @Test func linesWithNoWordsInCommonGetNoWordMarks() {
        let changes = WordDiff.changes("alpha beta", "gamma delta")
        #expect(changes.old.isEmpty && changes.new.isEmpty)
    }

    @Test func hugeLinesSkipTheWordDiff() {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let changes = WordDiff.changes(long, long + " more")
        #expect(changes.old.isEmpty && changes.new.isEmpty)
    }

    @Test func emptyInputHasNoFiles() {
        #expect(UnifiedDiff(parsing: "").files.isEmpty)
    }
}

private extension String {
    func slices(_ ranges: [Range<Int>]) -> [String] {
        let characters = Array(self)
        return ranges.map { String(characters[$0]) }
    }
}
