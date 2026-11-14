import Testing
@testable import ListfulCore

@Suite struct SortTests {
    func outline(_ text: String) -> Outline { MarkdownCodec.decode(text) }
    func titles(_ outline: Outline) -> [String] { outline.items.map(\.title) }

    @Test func sortsSiblingsAToZWithNumbersByValue() {
        var o = outline("- [ ] b\n- [ ] 10 ten\n- [ ] A\n- [ ] 2 two\n- [ ] \n")
        let changed0o = o.sortTasks(for: 0)
        #expect(changed0o)
        #expect(titles(o) == ["2 two", "10 ten", "A", "b", ""])
    }

    @Test func subtasksMoveWithTheirParents() {
        var o = outline("- [ ] b\n  - [ ] b1\n- [x] a\n  - [ ] a1\n    - [ ] a11\n")
        o.sortTasks(for: 2)  // "a" has subtasks, so those are sorted: just one
        #expect(titles(o) == ["b", "b1", "a", "a1", "a11"])
        o.sortTasks(for: 1)  // a leaf: sorts it with its siblings, of which it has none
        #expect(titles(o) == ["b", "b1", "a", "a1", "a11"])
        let parentless = outline("- [ ] b\n  - [ ] b1\n- [x] a\n  - [ ] a1\n    - [ ] a11\n- [ ] c\n")
        var p = parentless
        let changed5p = p.sortTasks(for: 5)
        #expect(changed5p)
        #expect(titles(p) == ["a", "a1", "a11", "b", "b1", "c"])
        #expect(p.items[0].state == .done)
        #expect(p.items.map(\.depth) == [0, 1, 2, 0, 1, 0])
    }

    @Test func aTaskWithSubtasksSortsThem() {
        var o = outline("- [ ] z\n- [ ] Parent\n  - [ ] c\n  - [ ] a\n    - [ ] deep\n  - [ ] b\n")
        let changed1o = o.sortTasks(for: 1)
        #expect(changed1o)
        #expect(titles(o) == ["z", "Parent", "a", "deep", "b", "c"])
    }

    @Test func topLevelSortsStayBetweenHeadings() {
        var o = outline("- [ ] y\n- [ ] x\n\n## H\n\n- [ ] b\n- [ ] a\n\n### Sub\n\n- [ ] d\n- [ ] c\n")
        let changed4o = o.sortTasks(for: 4)  // "b", under H
        #expect(changed4o)
        #expect(titles(o) == ["y", "x", "H", "a", "b", "Sub", "d", "c"])
        let changed0o = o.sortTasks(for: 0)
        #expect(changed0o)
        #expect(titles(o) == ["x", "y", "H", "a", "b", "Sub", "d", "c"])
        let changed5o = o.sortTasks(for: 5)  // the heading "Sub" sorts its section
        #expect(changed5o)
        #expect(titles(o) == ["x", "y", "H", "a", "b", "Sub", "c", "d"])
    }

    @Test func nothingToSort() {
        var o = outline("## H\n\n## Empty\n\n- [ ] only\n")
        #expect(o.sortRange(for: 0) == nil)
        #expect(o.sortRange(for: 2) == nil)
        let changed2o = o.sortTasks(for: 2)
        #expect(!changed2o)
        var sorted = outline("- [ ] a\n- [ ] b\n")
        #expect(sorted.sortRange(for: 0) == 0..<2)
        let changed0sorted = sorted.sortTasks(for: 0)
        #expect(!changed0sorted)
    }

    @Test func equalTitlesKeepTheirOrder() {
        var o = outline("- [ ] b\n- [ ] a\n  - [ ] first\n- [ ] a\n  - [ ] second\n")
        o.sortTasks(for: 0)
        #expect(titles(o) == ["a", "first", "a", "second", "b"])
    }
}
