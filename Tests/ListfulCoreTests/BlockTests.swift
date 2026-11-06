import Testing
@testable import ListfulCore

@Suite struct BlockTests {
    @Test func blockRangeTakesInHiddenSubtasksAndSections() {
        var o = outline(["a:0", "b:1", "c:0", "#H", "d:0", "#K"])
        o.setCollapsed(true, at: 0)
        #expect(o.blockRange(from: 0, to: 0) == 0..<2)
        #expect(o.blockRange(from: 2, to: 3) == 2..<4)
        o.setCollapsed(true, at: 3)
        #expect(o.blockRange(from: 2, to: 3) == 2..<5)
    }

    @Test func blockItemsAreRebasedToTopLevel() {
        let o = outline(["a:0", "b:1", "c:2", "d:1"])
        #expect(shape(Outline(items: o.blockItems(1..<4))) == ["b:0", "c:1", "d:0"])
    }

    @Test func removeBlockMovesOrphansOut() {
        var o = outline(["a:0", "b:1", "c:2", "d:0"])
        o.removeBlock(0..<2)
        #expect(shape(o) == ["c:0", "d:0"])
    }

    @Test func insertBlockGoesAfterACollapsedRowsSubtree() {
        var o = outline(["x:0", "a:1", "a2:2", "b:0"])
        o.setCollapsed(true, at: 1)
        let range = o.insertBlock(outline(["p:0", "q:1"]).items, at: 1)
        #expect(range == 3..<5)
        #expect(shape(o) == ["x:0", "a:1", "a2:2", "p:1", "q:2", "b:0"])
    }

    @Test func insertBlockGoesFirstUnderAnExpandedParent() {
        var o = outline(["a:0", "b:1"])
        o.insertBlock(outline(["p:0"]).items, at: 0)
        #expect(shape(o) == ["a:0", "p:1", "b:1"])
    }

    @Test func insertBlockReplacesAnEmptyRow() {
        var o = outline(["a:0", ":1"])
        let range = o.insertBlock(outline(["p:0", "q:0"]).items, at: 1)
        #expect(range == 1..<3)
        #expect(shape(o) == ["a:0", "p:1", "q:1"])
    }

    @Test func insertBlockGivesNewIDs() {
        var o = outline(["a:0"])
        let block = o.blockItems(0..<1)
        o.insertBlock(block, at: 0)
        #expect(o.items[0].id != o.items[1].id)
    }

    @Test func replaceBlockTakesTheFirstReplacedRowsDepth() {
        var o = outline(["a:0", "b:1", "c:2", "d:0"])
        let range = o.replaceBlock(1..<3, with: outline(["p:0", "q:1", "r:0"]).items)
        #expect(range == 1..<4)
        #expect(shape(o) == ["a:0", "p:1", "q:2", "r:1", "d:0"])
    }

    @Test func setDoneMarksTasksButNotHeadings() {
        var o = outline(["#H", "a:0", "b:0"])
        o.setDone(true, at: [0, 1, 2])
        #expect(o.items.map(\.state) == [.open, .done, .done])
        o.setDone(false, at: [1])
        #expect(o.items.map(\.state) == [.open, .open, .done])
    }
}

@Suite struct TaskClipboardTests {
    @Test func oneRowCopiesAsItsText() {
        #expect(TaskClipboard.plainText(outline(["Buy milk:0"]).items) == "Buy milk")
    }

    @Test func plainTextLeavesOutListfulsMarkers() {
        var o = outline(["a:0", "b:1"])
        o.toggleDone(at: 1)
        o.decruftDone()
        #expect(TaskClipboard.markdown(o.items) == "- [ ] a\n  - [x] b <!-- listful: decrufted -->\n")
        #expect(TaskClipboard.plainText(o.items) == "- [ ] a\n  - [x] b\n")
    }

    @Test func pastedTextBecomesTasks() {
        let items = TaskClipboard.items(from: "# Shopping\n\nmilk\n  - [x] eggs\n\n- bread\n")
        #expect(shape(Outline(items: items)) == ["#Shopping", "milk:0", "eggs:1", "bread:0"])
        #expect(items[2].state == .done)
    }
}
