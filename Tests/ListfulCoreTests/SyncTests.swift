import Foundation
import Testing
@testable import ListfulCore

@Suite struct TextMergeTests {
    let base = "- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d\n"

    @Test func oneSideChangedTakesThatSide() {
        let changed = "- [x] a\n- [ ] b\n- [ ] c\n- [ ] d\n"
        #expect(TextMerge.merge(base: base, mine: changed, theirs: base) == .merged(changed))
        #expect(TextMerge.merge(base: base, mine: base, theirs: changed) == .merged(changed))
    }

    @Test func changesToDifferentLinesAreBothKept() {
        let mine = "- [x] a\n- [ ] b\n- [ ] c\n- [ ] d\n"
        let theirs = "- [ ] a\n- [ ] b\n- [ ] c\n- [ ] d changed\n"
        #expect(TextMerge.merge(base: base, mine: mine, theirs: theirs)
            == .merged("- [x] a\n- [ ] b\n- [ ] c\n- [ ] d changed\n"))
    }

    @Test func insertionsAndDeletionsElsewhereAreBothKept() {
        let mine = "- [ ] a\n- [ ] new mine\n- [ ] b\n- [ ] c\n- [ ] d\n"
        let theirs = "- [ ] a\n- [ ] b\n- [ ] d\n"
        #expect(TextMerge.merge(base: base, mine: mine, theirs: theirs)
            == .merged("- [ ] a\n- [ ] new mine\n- [ ] b\n- [ ] d\n"))
    }

    @Test func insertionsAtTheSamePlaceKeepBothTheirsFirst() {
        let mine = base + "- [ ] from here\n"
        let theirs = base + "- [ ] from there\n"
        #expect(TextMerge.merge(base: base, mine: mine, theirs: theirs)
            == .merged(base + "- [ ] from there\n- [ ] from here\n"))
    }

    @Test func identicalChangesOnBothSidesMergeOnce() {
        let both = "- [ ] a\n- [x] b\n- [ ] c\n- [ ] d\n"
        let mine = both + "- [ ] e\n"
        #expect(TextMerge.merge(base: base, mine: mine, theirs: both) == .merged(mine))
    }

    @Test func differentChangesToTheSameLineConflict() {
        let mine = "- [ ] a\n- [ ] b here\n- [ ] c\n- [ ] d\n"
        let theirs = "- [ ] a\n- [ ] b there\n- [ ] c\n- [ ] d\n"
        #expect(TextMerge.merge(base: base, mine: mine, theirs: theirs) == .conflict)
    }

    @Test func editingALineTheOtherSideDeletedConflicts() {
        let mine = "- [ ] a\n- [ ] b edited\n- [ ] c\n- [ ] d\n"
        let theirs = "- [ ] a\n- [ ] c\n- [ ] d\n"
        #expect(TextMerge.merge(base: base, mine: mine, theirs: theirs) == .conflict)
    }
}

@Suite struct AdoptIdentitiesTests {
    @Test func unchangedAndEditedRowsKeepTheirIDs() {
        let old = outline(["a:0", "b:1", "c:0"])
        var new = outline(["a:0", "b edited:1", "c:0"])
        new.adoptIdentities(from: old)
        #expect(new.items.map(\.id) == old.items.map(\.id))
    }

    @Test func insertedRowsGetNewIDsAndOthersKeepTheirs() {
        let old = outline(["a:0", "c:0"])
        var new = outline(["a:0", "b:0", "c:0"])
        new.adoptIdentities(from: old)
        #expect(new.items[0].id == old.items[0].id)
        #expect(new.items[2].id == old.items[1].id)
        #expect(!old.items.map(\.id).contains(new.items[1].id))
    }

    @Test func removedRowsDontShiftIdentities() {
        let old = outline(["a:0", "b:0", "c:0"])
        var new = outline(["a:0", "c:0"])
        new.adoptIdentities(from: old)
        #expect(new.items.map(\.id) == [old.items[0].id, old.items[2].id])
    }
}

@Suite struct ConflictCopyTests {
    @Test func namesCopyBesideTheListAndAvoidsClashes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ConflictCopyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = folder.appending(path: "Groceries.md")
        let shown = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14, minute: 5)))

        let first = TaskLibrary.conflictCopyURL(for: list, date: shown)
        #expect(first.lastPathComponent == "Groceries (conflict 2026-10-19 14-05).md")
        try "".write(to: first, atomically: true, encoding: .utf8)
        let second = TaskLibrary.conflictCopyURL(for: list, date: shown)
        #expect(second.lastPathComponent == "Groceries (conflict 2026-10-19 14-05) 2.md")
    }
}
