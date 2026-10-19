import Testing
@testable import ListfulCore

/// Builds an outline from "title:depth" shorthand, e.g. ["a:0", "b:1"].
/// Entries starting with "#" are headings: "##B" is a level-2 heading "B".
func outline(_ spec: [String]) -> Outline {
    Outline(items: spec.map { entry in
        if entry.hasPrefix("#") {
            let level = entry.prefix(while: { $0 == "#" }).count
            return TaskItem(title: String(entry.dropFirst(level)), headingLevel: level)
        }
        let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
        return TaskItem(title: String(parts[0]), depth: Int(parts[1])!)
    })
}

/// Renders an outline back to the same shorthand.
func shape(_ outline: Outline) -> [String] {
    outline.items.map { item in
        if let level = item.headingLevel { return String(repeating: "#", count: level) + item.title }
        return "\(item.title):\(item.depth)"
    }
}

@Suite struct OutlineTests {
    @Test func initClampsDepths() {
        let o = outline(["a:2", "b:5", "c:1"])
        #expect(shape(o) == ["a:0", "b:1", "c:1"])
    }

    @Test func subtreeAndParent() {
        let o = outline(["a:0", "b:1", "c:2", "d:1", "e:0"])
        #expect(o.subtreeEnd(0) == 4)
        #expect(o.subtreeEnd(1) == 3)
        #expect(o.parentIndex(2) == 1)
        #expect(o.parentIndex(3) == 0)
        #expect(o.parentIndex(0) == nil)
        #expect(o.previousSiblingIndex(3) == 1)
        #expect(o.previousSiblingIndex(1) == nil)
        #expect(o.hasChildren(1))
        #expect(!o.hasChildren(3))
    }

    @Test func indentMovesSubtreeUnderPreviousSibling() {
        var o = outline(["a:0", "b:0", "c:1", "d:0"])
        let r = o.indent(at: 1)
        #expect(r)
        #expect(shape(o) == ["a:0", "b:1", "c:2", "d:0"])
    }

    @Test func indentWithoutPreviousSiblingFails() {
        var o = outline(["a:0", "b:1"])
        let first = o.indent(at: 0)
        #expect(!first)
        let child = o.indent(at: 1)
        #expect(!child)
        #expect(shape(o) == ["a:0", "b:1"])
    }

    @Test func indentExpandsCollapsedParent() {
        var o = outline(["a:0", "x:1", "b:0"])
        o.setCollapsed(true, at: 0)
        o.indent(at: 2)
        #expect(!o.items[0].isCollapsed)
        #expect(shape(o) == ["a:0", "x:1", "b:1"])
    }

    @Test func outdentPlacesAfterParentSubtree() {
        var o = outline(["a:0", "b:1", "c:2", "d:1", "e:0"])
        let r = o.outdent(at: 1)
        #expect(r == 2)
        #expect(shape(o) == ["a:0", "d:1", "b:0", "c:1", "e:0"])
    }

    @Test func returnOnEmptyNestedTaskOutdents() {
        var o = outline(["a:0", "b:1", ":1"])
        let r = o.returnKey(at: 2)
        #expect(r.index == 2)
        #expect(r.caret == nil)
        #expect(shape(o) == ["a:0", "b:1", ":0"])
    }

    @Test func returnOnEmptyTopLevelTaskInserts() {
        var o = outline(["a:0", ":0"])
        let r = o.returnKey(at: 1)
        #expect(r.index == 2)
        #expect(shape(o) == ["a:0", ":0", ":0"])
    }

    @Test func returnOnNonEmptyNestedTaskInserts() {
        var o = outline(["a:0", "b:1"])
        let r = o.returnKey(at: 1)
        #expect(r.index == 2)
        #expect(shape(o) == ["a:0", "b:1", ":1"])
    }

    @Test func returnMidLineSplitsTask() {
        var o = outline(["hello world:0", "x:0"])
        let r = o.returnKey(at: 0, selection: 5..<5)
        #expect(r.index == 1)
        #expect(r.caret == 0)
        #expect(shape(o) == ["hello:0", " world:0", "x:0"])
    }

    @Test func returnMidLineOfParentSplitsIntoFirstChild() {
        var o = outline(["abcd:0", "c:1"])
        let r = o.returnKey(at: 0, selection: 2..<2)
        #expect(r.index == 1)
        #expect(shape(o) == ["ab:0", "cd:1", "c:1"])
    }

    @Test func returnDeletesSelectionBeforeSplitting() {
        var o = outline(["abcdef:0"])
        let r = o.returnKey(at: 0, selection: 2..<4)
        #expect(r.index == 1)
        #expect(shape(o) == ["ab:0", "ef:0"])
    }

    @Test func returnAtStartInsertsEmptyTaskAbove() {
        var o = outline(["a:0", "b:1", "c:2"])
        let r = o.returnKey(at: 1, selection: 0..<0)
        #expect(r.index == 2)
        #expect(r.caret == 0)
        #expect(shape(o) == ["a:0", ":1", "b:1", "c:2"])
    }

    @Test func returnSplitsByUTF16Offset() {
        var o = outline(["🙂ab:0"])
        o.returnKey(at: 0, selection: 3..<3)
        #expect(shape(o) == ["🙂a:0", "b:0"])
    }

    @Test func outdentTopLevelFails() {
        var o = outline(["a:0"])
        let r = o.outdent(at: 0)
        #expect(r == nil)
    }

    @Test func insertAfterLeafAddsSibling() {
        var o = outline(["a:0", "b:1", "c:0"])
        let r = o.insertItem(after: 1)
        #expect(r == 2)
        #expect(shape(o) == ["a:0", "b:1", ":1", "c:0"])
    }

    @Test func insertAfterExpandedParentAddsFirstChild() {
        var o = outline(["a:0", "b:1"])
        let r = o.insertItem(after: 0)
        #expect(r == 1)
        #expect(shape(o) == ["a:0", ":1", "b:1"])
    }

    @Test func insertAfterCollapsedParentAddsSiblingAfterSubtree() {
        var o = outline(["a:0", "b:1", "c:0"])
        o.setCollapsed(true, at: 0)
        let r = o.insertItem(after: 0)
        #expect(r == 2)
        #expect(shape(o) == ["a:0", "b:1", ":0", "c:0"])
    }

    @Test func moveUpAndDownSwapSiblingSubtrees() {
        var o = outline(["a:0", "a1:1", "b:0", "b1:1", "c:0"])
        let up = o.moveUp(at: 2)
        #expect(up == 0)
        #expect(shape(o) == ["b:0", "b1:1", "a:0", "a1:1", "c:0"])
        let down = o.moveDown(at: 2)
        #expect(down == 3)
        #expect(shape(o) == ["b:0", "b1:1", "c:0", "a:0", "a1:1"])
        let pastEnd = o.moveDown(at: 3)
        #expect(pastEnd == nil)
        let noSibling = o.moveUp(at: 1)
        #expect(noSibling == nil)
    }

    @Test func removeSubtree() {
        var o = outline(["a:0", "b:1", "c:0"])
        o.removeSubtree(at: 0)
        #expect(shape(o) == ["c:0"])
    }

    @Test func toggleDoneCyclesThroughStates() {
        var o = outline(["a:0"])
        o.toggleDone(at: 0)
        #expect(o.items[0].state == .done)
        o.decruftDone()
        #expect(o.items[0].state == .decrufted)
        o.toggleDone(at: 0)
        #expect(o.items[0].state == .open)
    }

    @Test func decruftOnlyAffectsDone() {
        var o = outline(["a:0", "b:0", "c:0"])
        o.toggleDone(at: 0)
        o.toggleDone(at: 2)
        let r = o.decruftDone()
        #expect(r == 2)
        #expect(o.items.map(\.state) == [.decrufted, .open, .decrufted])
    }

    @Test func visibilityHidesCollapsedChildren() {
        var o = outline(["a:0", "b:1", "c:2", "d:0"])
        o.setCollapsed(true, at: 0)
        #expect(o.visibleIndices(showDecrufted: false) == [0, 3])
        o.setCollapsed(false, at: 0)
        o.setCollapsed(true, at: 1)
        #expect(o.visibleIndices(showDecrufted: false) == [0, 1, 3])
    }

    @Test func visibilityHidesDecruftedSubtreesUnlessShown() {
        var o = outline(["a:0", "b:1", "c:0"])
        o.toggleDone(at: 0)
        o.decruftDone()
        #expect(o.visibleIndices(showDecrufted: false) == [2])
        #expect(o.visibleIndices(showDecrufted: true) == [0, 1, 2])
    }

    // MARK: Headings

    @Test func headingsAreTopLevelAndResetDepth() {
        let o = Outline(items: [
            TaskItem(title: "a", depth: 0),
            TaskItem(title: "H", state: .done, depth: 3, headingLevel: 9),
            TaskItem(title: "b", depth: 1),
        ])
        #expect(shape(o) == ["a:0", "###H", "b:0"])
        #expect(o.items[1].state == .open)
        #expect(!o.hasChildren(1))
    }

    @Test func sectionsEndAtSameOrHigherHeading() {
        let o = outline(["#A", "a:0", "##B", "b:0", "###C", "c:0", "##D", "#E"])
        #expect(o.sectionEnd(0) == 7)
        #expect(o.sectionEnd(2) == 6)
        #expect(o.sectionEnd(4) == 6)
        #expect(o.canCollapse(0))
        #expect(!o.canCollapse(6))
        #expect(!o.canCollapse(7))
    }

    @Test func collapsedHeadingHidesItsSection() {
        var o = outline(["#A", "a:0", "a1:1", "##B", "b:0", "#C", "c:0"])
        o.setCollapsed(true, at: 0)
        #expect(o.visibleIndices(showDecrufted: false) == [0, 5, 6])
        o.setCollapsed(false, at: 0)
        o.setCollapsed(true, at: 3)
        #expect(o.visibleIndices(showDecrufted: false) == [0, 1, 2, 3, 5, 6])
    }

    @Test func headingsCantBeIndentedDoneOrParents() {
        var o = outline(["a:0", "#H", "b:0"])
        let indentHeading = o.indent(at: 1)
        let indentUnderHeading = o.indent(at: 2)
        #expect(!indentHeading && !indentUnderHeading)
        o.toggleDone(at: 1)
        #expect(o.items[1].state == .open)
        #expect(shape(o) == ["a:0", "#H", "b:0"])
    }

    @Test func tasksMoveAcrossHeadingsButHeadingsDont() {
        var o = outline(["a:0", "#H", "b:0", "b1:1"])
        let up = o.moveUp(at: 2)
        #expect(up == 1)
        #expect(shape(o) == ["a:0", "b:0", "b1:1", "#H"])
        let headingMove = o.moveUp(at: 3)
        #expect(headingMove == nil)
        let down = o.moveDown(at: 1)
        #expect(down == 2)
        #expect(shape(o) == ["a:0", "#H", "b:0", "b1:1"])
    }

    @Test func movingIntoCollapsedSectionExpandsIt() {
        var o = outline(["#A", "x:0", "y:0", "#B", "z:0"])
        o.setCollapsed(true, at: 0)
        _ = o.moveUp(at: 4)
        #expect(shape(o) == ["#A", "x:0", "y:0", "z:0", "#B"])
        #expect(!o.items[0].isCollapsed)
    }

    @Test func insertingAfterCollapsedHeadingExpandsIt() {
        var o = outline(["#A", "x:0"])
        o.setCollapsed(true, at: 0)
        let new = o.insertItem(after: 0)
        #expect(new == 1)
        #expect(shape(o) == ["#A", ":0", "x:0"])
        #expect(!o.items[0].isCollapsed)
    }

    @Test func makeHeadingOutdentsAndPromotesChildren() {
        var o = outline(["p:0", "t:1", "c:2", "g:3", "s:1"])
        o.toggleDone(at: 1)
        let index = o.makeHeading(level: 2, at: 1)
        #expect(index == 2)
        #expect(shape(o) == ["p:0", "s:1", "##t", "c:0", "g:1"])
        #expect(o.items[index].state == .open)

        o.makeTask(at: index)
        #expect(shape(o) == ["p:0", "s:1", "t:0", "c:0", "g:1"])
    }
}
