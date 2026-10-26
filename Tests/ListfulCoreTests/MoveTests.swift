import Testing
@testable import ListfulCore

/// Drag-and-drop moves: `moveDepths`, `dropTarget` and `move(at:to:depth:)`.
@Suite struct MoveTests {
    @Test func moveDownCarriesSubtree() {
        var o = outline(["a:0", "b:1", "c:0", "d:0"])
        let index = o.move(at: 0, to: 3, depth: 0)
        #expect(index == 1)
        #expect(shape(o) == ["c:0", "a:0", "b:1", "d:0"])
    }

    @Test func moveUpCarriesSubtree() {
        var o = outline(["a:0", "b:0", "c:0", "d:1"])
        let index = o.move(at: 2, to: 0, depth: 0)
        #expect(index == 0)
        #expect(shape(o) == ["c:0", "d:1", "a:0", "b:0"])
    }

    @Test func moveToEnd() {
        var o = outline(["a:0", "b:1", "c:0"])
        let index = o.move(at: 0, to: 3, depth: 1)
        #expect(index == 1)
        #expect(shape(o) == ["c:0", "a:1", "b:2"])
    }

    @Test func moveInPlaceChangesDepth() {
        var o = outline(["a:0", "b:0", "c:1"])
        // Before itself or just after its own subtree are the same gap.
        let before = o.move(at: 1, to: 1, depth: 1)
        #expect(before == 1)
        #expect(shape(o) == ["a:0", "b:1", "c:2"])
        let after = o.move(at: 1, to: 3, depth: 0)
        #expect(after == 1)
        #expect(shape(o) == ["a:0", "b:0", "c:1"])
    }

    @Test func depthsRunFromNextItemToOneBelowPrevious() {
        let o = outline(["a:0", "b:1", "c:2", "d:1", "e:0", "x:0"])
        // Between c (2) and d (1): 1...3.
        #expect(o.moveDepths(at: 5, to: 3) == 1...3)
        // At the very top: only 0.
        #expect(o.moveDepths(at: 5, to: 0) == 0...0)
        // At the end, after e: 0...1.
        #expect(o.moveDepths(at: 0, to: 6) == 0...1)
    }

    @Test func cannotMoveIntoOwnSubtreeOrMoveHeadings() {
        var o = outline(["a:0", "b:1", "c:1", "#H", "d:0"])
        #expect(o.moveDepths(at: 0, to: 2) == nil)
        #expect(o.moveDepths(at: 3, to: 0) == nil)
        let refused = o.move(at: 0, to: 2, depth: 1)
        #expect(refused == nil)
        let tooDeep = o.move(at: 4, to: 0, depth: 1)
        #expect(tooDeep == nil)
        #expect(shape(o) == ["a:0", "b:1", "c:1", "#H", "d:0"])
    }

    @Test func nothingNestsUnderAHeading() {
        let o = outline(["a:0", "#H", "b:0", "c:0"])
        // Right after the heading, and before it (b would follow a heading).
        #expect(o.moveDepths(at: 3, to: 2) == 0...0)
        #expect(o.moveDepths(at: 3, to: 1) == 0...1)
    }

    @Test func movingAcrossHeadingsChangesSection() {
        var o = outline(["#A", "a:0", "#B", "b:0"])
        o.setCollapsed(true, at: 2)
        let index = o.move(at: 1, to: 4, depth: 0)
        #expect(index == 3)
        #expect(shape(o) == ["#A", "#B", "b:0", "a:0"])
        #expect(!o.items[1].isCollapsed)
    }

    @Test func dropUnderCollapsedTaskExpandsIt() {
        var o = outline(["a:0", "b:1", "c:2", "d:0"])
        o.setCollapsed(true, at: 0)
        // Visible rows: a, d. Dropping d between a and... the end, as a's child.
        let target = o.dropTarget(moving: 3, afterVisible: 0, beforeVisible: nil)
        #expect(target?.destination == 4)
        // c (hidden, depth 2) would allow up to 3; the visible a caps it at 1.
        #expect(target?.depths == 0...1)
        let index = o.move(at: 3, to: 4, depth: 1)
        #expect(index == 3)
        #expect(shape(o) == ["a:0", "b:1", "c:2", "d:1"])
        #expect(!o.items[0].isCollapsed)
    }

    @Test func dropTargetAtTop() {
        let o = outline(["a:0", "b:0", "c:1"])
        let target = o.dropTarget(moving: 1, afterVisible: nil, beforeVisible: 0)
        #expect(target?.destination == 0)
        #expect(target?.depths == 0...0)
    }
}
