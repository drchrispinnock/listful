import Foundation
import Testing
@testable import ListfulCore

@Suite struct MarkdownCodecTests {
    let sample = """
        - [ ] Groceries <!-- listful: collapsed -->
          - [x] Milk
          - [ ] Bread
        - [x] Old thing <!-- listful: decrufted -->
          - [ ] Leftover
        - [ ] Empty parent marker ignored

        """

    @Test func decodesStatesDepthsAndFlags() {
        let o = MarkdownCodec.decode(sample)
        #expect(o.items.map(\.title) == ["Groceries", "Milk", "Bread", "Old thing", "Leftover", "Empty parent marker ignored"])
        #expect(o.items.map(\.depth) == [0, 1, 1, 0, 1, 0])
        #expect(o.items.map(\.state) == [.open, .done, .open, .decrufted, .open, .open])
        #expect(o.items.map(\.isCollapsed) == [true, false, false, false, false, false])
    }

    @Test func roundTripsCanonicalText() {
        #expect(MarkdownCodec.encode(MarkdownCodec.decode(sample)) == sample)
    }

    @Test func collapsedFlagOnlyWrittenWhenThereAreChildren() {
        var o = Outline(items: [TaskItem(title: "solo", isCollapsed: true)])
        #expect(MarkdownCodec.encode(o) == "- [ ] solo\n")
        o.insertItem(after: 0)
        #expect(MarkdownCodec.encode(o) == "- [ ] solo\n- [ ] \n")
    }

    @Test func readsMarkersFromBeforeTheRename() {
        let o = MarkdownCodec.decode("- [ ] a <!-- taskmgr: collapsed -->\n  - [x] b <!-- taskmgr: decrufted -->\n")
        #expect(o.items.map(\.title) == ["a", "b"])
        #expect(o.items[0].isCollapsed)
        #expect(o.items[1].state == .decrufted)
        #expect(MarkdownCodec.encode(o) == "- [ ] a <!-- listful: collapsed -->\n  - [x] b <!-- listful: decrufted -->\n")
    }

    @Test func emptyOutlineEncodesToEmptyString() {
        #expect(MarkdownCodec.encode(Outline()) == "")
        #expect(MarkdownCodec.decode("").isEmpty)
    }

    @Test func acceptsHandWrittenVariants() {
        let text = """
            Intro line
            * plain bullet
            \t+ [X] tab-indented done
                - four-space child
            -
            """
        let o = MarkdownCodec.decode(text)
        #expect(o.items.map(\.title) == ["Intro line", "plain bullet", "tab-indented done", "four-space child", ""])
        #expect(o.items.map(\.depth) == [0, 0, 1, 1, 0])
        #expect(o.items.map(\.state) == [.open, .open, .done, .open, .open])
    }

    // MARK: Headings and titles

    let headed = """
        # Weekend

        - [ ] Loose task

        ## Chores <!-- listful: collapsed -->

        - [ ] Laundry
          - [x] Sort colours

        ### Garden

        - [ ] Mow

        # Fun

        - [x] Cinema <!-- listful: decrufted -->

        """

    @Test func decodesTitleAndHeadings() {
        let o = MarkdownCodec.decode(headed)
        #expect(o.title == "Weekend")
        #expect(o.items.map(\.title) == ["Loose task", "Chores", "Laundry", "Sort colours", "Garden", "Mow", "Fun", "Cinema"])
        #expect(o.items.map(\.headingLevel) == [nil, 2, nil, nil, 3, nil, 1, nil])
        #expect(o.items.map(\.depth) == [0, 0, 0, 1, 0, 0, 0, 0])
        #expect(o.items[1].isCollapsed)
    }

    @Test func roundTripsTitleAndHeadings() {
        #expect(MarkdownCodec.encode(MarkdownCodec.decode(headed)) == headed)
    }

    @Test func titleOnlyComesFromALevelOneHeadingOnTheFirstLine() {
        #expect(MarkdownCodec.decode("\n\n# Top\n- [ ] a\n").title == "Top")
        #expect(MarkdownCodec.decode("## Not title\n").title == nil)
        #expect(MarkdownCodec.decode("- [ ] a\n# Later\n").title == nil)
        #expect(MarkdownCodec.decode("- [ ] a\n# Later\n").items[1].headingLevel == 1)
        #expect(MarkdownCodec.title(in: "\n# Top <!-- listful: collapsed -->\n- [ ] a") == "Top")
        #expect(MarkdownCodec.title(in: "- [ ] a\n# Later") == nil)
        #expect(MarkdownCodec.title(in: "") == nil)
    }

    @Test func titleOnlyOutlineEncodes() {
        #expect(MarkdownCodec.encode(Outline(title: "Empty")) == "# Empty\n")
    }

    @Test func headingSyntaxEdgeCases() {
        #expect(MarkdownCodec.parseHeading("## Title ##")! == (2, "Title"))
        #expect(MarkdownCodec.parseHeading("# C#")! == (1, "C#"))
        #expect(MarkdownCodec.parseHeading("#")! == (1, ""))
        #expect(MarkdownCodec.parseHeading("#tag") == nil)
        #expect(MarkdownCodec.parseHeading("#### Deep") == nil)

        // Not headings: deeper levels, indented, or inside a task's text.
        let o = MarkdownCodec.decode("- [ ] first\n#### Deep\n  # indented\n- [ ] # literal\n")
        #expect(o.items.allSatisfy { !$0.isHeading })
        #expect(o.items.map(\.title) == ["first", "#### Deep", "# indented", "# literal"])
    }

    @Test func headingResetsIndentation() {
        let o = MarkdownCodec.decode("- [ ] a\n  - [ ] b\n## H\n  - [ ] c\n    - [ ] d\n")
        #expect(o.items.map(\.depth) == [0, 1, 0, 0, 1])
    }

    @Test func irregularIndentationNestsRelatively() {
        let text = """
            - a
               - b
                     - c
               - d
             - e
            """
        let o = MarkdownCodec.decode(text)
        #expect(o.items.map(\.depth) == [0, 1, 2, 1, 1])
    }

    @Test func fileStoreRoundTripsAndTreatsMissingFileAsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MarkdownFileStore(fileURL: dir.appending(path: "nested/Tasks.md"))

        #expect(try store.load().isEmpty)

        let original = MarkdownCodec.decode(sample)
        try store.save(original)
        let reloaded = try store.load()
        #expect(MarkdownCodec.encode(reloaded) == sample)
    }
}
