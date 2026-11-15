import Foundation
import Testing
@testable import ConstellationCore

@Suite struct SessionGridTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1010, height: 610)

    @Test func twoSitSideBySide() {
        let frames = SessionGrid.frames(count: 2, in: bounds, gap: 10)
        #expect(frames == [CGRect(x: 0, y: 0, width: 500, height: 610), CGRect(x: 510, y: 0, width: 500, height: 610)])
    }

    @Test func threeAreOneTallAndTwoStacked() {
        let frames = SessionGrid.frames(count: 3, in: bounds, gap: 10)
        #expect(frames == [
            CGRect(x: 0, y: 0, width: 500, height: 610),
            CGRect(x: 510, y: 0, width: 500, height: 300),
            CGRect(x: 510, y: 310, width: 500, height: 300),
        ])
    }

    @Test func fourAreTwoByTwo() {
        let frames = SessionGrid.frames(count: 4, in: bounds, gap: 10)
        #expect(frames.map(\.origin) == [CGPoint(x: 0, y: 0), CGPoint(x: 510, y: 0), CGPoint(x: 0, y: 310), CGPoint(x: 510, y: 310)])
        #expect(frames.allSatisfy { $0.size == CGSize(width: 500, height: 300) })
    }

    @Test func needsTwoToFourDifferentSessions() {
        let a = UUID(), b = UUID()
        #expect(SessionGrid([a]) == nil)
        #expect(SessionGrid([a, a]) == nil)
        #expect(SessionGrid([a, b], focus: b)?.focusedID == b)
        var grid = SessionGrid([a, b])!
        let added = [grid.add(UUID()), grid.add(UUID()), grid.add(UUID())]
        #expect(added == [true, true, false])
        #expect(grid.ids.count == 4)
    }

    @Test func removingFocusPassesBackAndTheLastTwoSplitUp() {
        let a = UUID(), b = UUID(), c = UUID()
        var grid = SessionGrid([a, b, c], focus: c)!
        let left = grid.remove(c)
        #expect(left == nil)
        #expect(grid.ids == [a, b])
        #expect(grid.focusedID == b)
        let last = grid.remove(a)
        #expect(last == b)
        #expect(grid.ids == [a, b])
    }

    @Test func arrowsFollowTheLayout() {
        let a = UUID(), b = UUID(), c = UUID()
        var grid = SessionGrid([a, b, c])!
        #expect(grid.neighbour(.right) == b)
        #expect(grid.neighbour(.left) == nil)
        grid.focus(c)
        #expect(grid.neighbour(.up) == b)
        #expect(grid.neighbour(.left) == a)
        #expect(grid.neighbour(.down) == nil)
    }
}
