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
        #expect(o.preamble == ["Intro line"])
        #expect(o.items.map(\.title) == ["plain bullet", "tab-indented done", "four-space child", ""])
        #expect(o.items.map(\.depth) == [0, 1, 1, 0])
        #expect(o.items.map(\.state) == [.open, .done, .open, .open])
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
        #expect(o.items.map(\.title) == ["first", "# literal"])
        #expect(o.items[0].notes == ["#### Deep", "  # indented"])
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

    // MARK: - Heading attribute blocks

    @Test func headingAttributeBlocksAreHiddenButKept() {
        let text = """
        # Project {#top}

        ## Setup {#setup .wide}

        - [ ] Install

        ### Notes {-}

        - [ ] Read
        """ + "\n"
        let outline = MarkdownCodec.decode(text)
        #expect(outline.title == "Project")
        #expect(outline.titleAttributes == "{#top}")
        #expect(outline.items.map(\.title) == ["Setup", "Install", "Notes", "Read"])
        #expect(outline.items[0].attributes == "{#setup .wide}")
        #expect(outline.items[2].attributes == "{-}")
        #expect(MarkdownCodec.encode(outline) == text)
        #expect(MarkdownCodec.title(in: text) == "Project")
    }

    @Test func renamingAHeadingKeepsItsAttributes() {
        var outline = MarkdownCodec.decode("## Setup {#setup}\n")
        outline.setTitle("Getting started", at: 0)
        #expect(MarkdownCodec.encode(outline) == "## Getting started {#setup}\n")
    }

    @Test func onlyATrailingBlockAfterTextIsAnAttributeBlock() {
        #expect(MarkdownCodec.splitAttributes("{#only}") == ("{#only}", nil))
        #expect(MarkdownCodec.splitAttributes("Use {braces} here") == ("Use {braces} here", nil))
        #expect(MarkdownCodec.splitAttributes("Set {a} {#b}") == ("Set {a}", "{#b}"))
        #expect(MarkdownCodec.splitAttributes("Empty {}") == ("Empty", "{}"))
    }

    // MARK: Notes (lines that aren't tasks)

    @Test func taskAttributeBlocksAreHiddenButKept() {
        let text = "- [ ] Task {#x}\n  - [x] Sub {.y} <!-- listful: decrufted -->\n"
        let outline = MarkdownCodec.decode(text)
        #expect(outline.items.map(\.title) == ["Task", "Sub"])
        #expect(outline.items.map(\.attributes) == ["{#x}", "{.y}"])
        #expect(MarkdownCodec.encode(outline) == text)
    }

    let withNotes = """
        # Reading

        Books I mean to get to.
        Roughly in order.

        - [ ] Herriot
          - [ ] Vet in Harness
          - [ ] {#id: Reading_3_Clarkson}
          - [ ] Vets Might Fly
            borrowed from Sam

        ## Clarkson

        Farming ones first.

        1. Diddly Squat
        2. The Farmer's Year

        - [ ] Diddly Squat

        """

    @Test func linesThatAreNotTasksBecomeNotesOfTheItemBefore() {
        let o = MarkdownCodec.decode(withNotes)
        #expect(o.preamble == ["Books I mean to get to.", "Roughly in order."])
        #expect(o.items.map(\.title) == ["Herriot", "Vet in Harness", "Vets Might Fly", "Clarkson", "Diddly Squat"])
        #expect(o.items[1].notes == ["  - [ ] {#id: Reading_3_Clarkson}"])
        #expect(o.items[2].notes == ["    borrowed from Sam"])
        #expect(o.items[3].notes == ["Farming ones first.", "", "1. Diddly Squat", "2. The Farmer's Year"])
        // The depths ignore the notes.
        #expect(o.items.map(\.depth) == [0, 1, 1, 0, 0])
    }

    @Test func notesRoundTrip() {
        #expect(MarkdownCodec.encode(MarkdownCodec.decode(withNotes)) == withNotes)
    }

    @Test func notesMoveWithTheirTask() {
        var o = MarkdownCodec.decode(withNotes)
        o.moveUp(at: 2)
        #expect(Array(o.items.map(\.title)[1...2]) == ["Vets Might Fly", "Vet in Harness"])
        #expect(o.items[1].notes == ["    borrowed from Sam"])
        #expect(o.items[2].notes == ["  - [ ] {#id: Reading_3_Clarkson}"])
    }

    @Test func joiningKeepsTheJoinedTasksNotes() {
        var o = MarkdownCodec.decode("- [ ] a\n  note a\n- [ ] b\n  note b\n")
        o.join(1, into: 0)
        #expect(o.items.map(\.title) == ["ab"])
        #expect(o.items[0].notes == ["  note a", "", "  note b"])
    }

    @Test func paragraphsToShow() {
        let notes = ["Farming ones first,", "  in order. {.lead}", "", "  - [ ] {#id: x}", "{: .note}",
                     "<!-- a comment -->", "1. Diddly Squat"]
        #expect(MarkdownCodec.paragraphs(of: notes) == ["Farming ones first, in order.", "1. Diddly Squat"])
        #expect(MarkdownCodec.paragraphs(of: ["  - [ ] {#id: x}"]).isEmpty)
        #expect(MarkdownCodec.paragraphs(of: ["1. One", "2. Two", "> Quote", "goes on"])
            == ["1. One", "2. Two", "> Quote goes on"])
    }

    @Test func pastedPlainLinesStayTasks() {
        let o = MarkdownCodec.decode("milk\n  eggs\n", plainLinesAreTasks: true)
        #expect(o.items.map(\.title) == ["milk", "eggs"])
        #expect(o.items.allSatisfy { $0.notes.isEmpty })
    }
}
