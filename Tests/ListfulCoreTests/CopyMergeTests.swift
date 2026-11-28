import Foundation
import Testing
@testable import ListfulCore

private func outline(_ text: String) -> Outline { MarkdownCodec.decode(text) }

private func merge(_ a: String, _ b: String, base: String? = nil, template: String? = nil, aIsMine: Bool = false) -> String {
    MarkdownCodec.encode(RepeatingChecklists.mergeVersions(
        outline(a), outline(b), base: base.map(outline), template: template.map(outline), aIsMine: aIsMine))
}

/// Two devices make the same day's copy while out of touch and each tick
/// things off; the versions meet when they sync.
@Suite struct CopyMergeTests {
    let made = """
        # Daily — Thu 26 Nov

        - [ ] Thursday
          - [ ] Armin email
          - [ ] Slack renewal
        - [ ] Friday
          - [ ] AWS savings

        ## Evening

        - [ ] Bass practice
        - [ ] Prayers

        """

    @Test func ticksFromBothSidesAndAdditionsAreKept() {
        let train = """
            # Daily — Thu 26 Nov

            - [ ] Thursday
              - [x] Armin email
              - [ ] Slack renewal
              - [ ] Butchers
            - [ ] Friday
              - [ ] AWS savings

            ## Evening

            - [ ] Bass practice
            - [ ] Prayers

            """
        let home = """
            # Daily — Thu 26 Nov

            - [ ] Thursday
              - [ ] Armin email
              - [ ] Slack renewal
            - [ ] Friday
              - [ ] AWS savings

            ## Evening

            - [x] Bass practice
            - [ ] Prayers
            - [ ] Wind down

            """
        let expected = """
            # Daily — Thu 26 Nov

            - [ ] Thursday
              - [x] Armin email
              - [ ] Slack renewal
              - [ ] Butchers
            - [ ] Friday
              - [ ] AWS savings

            ## Evening

            - [x] Bass practice
            - [ ] Prayers
            - [ ] Wind down

            """
        #expect(merge(train, home, base: made) == expected)
        #expect(merge(home, train, base: made) == expected)
        #expect(merge(train, home) == expected)
    }

    @Test func untickingOnOneSideWinsOverTheBase() {
        let base = "- [x] Armin email\n- [ ] Slack renewal\n"
        let unticked = "- [ ] Armin email\n- [ ] Slack renewal\n"
        let other = "- [x] Armin email\n- [x] Slack renewal\n"
        #expect(merge(unticked, other, base: base) == "- [ ] Armin email\n- [x] Slack renewal\n")
        // Without a base, done wins.
        #expect(merge(unticked, other) == "- [x] Armin email\n- [x] Slack renewal\n")
    }

    @Test func aTaskDecruftedOnOneSideGoesKeepingOpenSubtasks() {
        let base = "- [ ] Thursday\n  - [ ] Armin email\n  - [ ] Slack renewal\n- [ ] Friday\n"
        let ticked = "- [x] Thursday\n  - [x] Armin email\n  - [ ] Slack renewal\n- [ ] Friday\n"
        let decrufted = "- [ ] Slack renewal\n- [ ] Friday\n"
        #expect(merge(ticked, decrufted, base: base) == "- [ ] Slack renewal\n- [ ] Friday\n")
        #expect(merge(decrufted, ticked, base: base) == "- [ ] Slack renewal\n- [ ] Friday\n")
    }

    @Test func aMoveOnOneSideIsFollowedNotDuplicated() {
        let base = "- [ ] Thursday\n  - [ ] AWS savings\n- [ ] Friday\n  - [ ] Slack renewal\n"
        let moved = "- [ ] Thursday\n- [ ] Friday\n  - [ ] Slack renewal\n  - [ ] AWS savings\n"
        let ticked = "- [ ] Thursday\n  - [x] AWS savings\n- [ ] Friday\n  - [ ] Slack renewal\n"
        let expected = "- [ ] Thursday\n- [ ] Friday\n  - [ ] Slack renewal\n  - [x] AWS savings\n"
        #expect(merge(ticked, moved, base: base) == expected)
        #expect(merge(moved, ticked, base: base) == expected)
    }

    @Test func aMoveToAnotherHeadingIsFollowed() {
        let base = "- [ ] Call Bob\n\n## Evening\n\n- [ ] Read\n"
        let moved = "## Evening\n\n- [ ] Read\n- [ ] Call Bob\n"
        #expect(merge(base, moved, base: base) == "## Evening\n\n- [ ] Read\n- [ ] Call Bob\n")
    }

    @Test func openTasksAreOnlyDroppedWhenThisDeviceDeletedThem() {
        let base = "- [ ] Armin email\n- [ ] Slack renewal\n"
        let deleted = "- [ ] Slack renewal\n"
        // The other side may never have had it (a different carry-over).
        #expect(merge(base, deleted, base: base) == base)
        // This device deleted it.
        #expect(merge(deleted, base, base: base, aIsMine: true) == deleted)
        #expect(merge(deleted, base, base: base) == "- [ ] Armin email\n- [ ] Slack renewal\n")
    }

    @Test func templateTasksDecruftedElsewhereStayGoneButCarriedOnesStay() {
        let template = "# Daily\n\n## Getting Up\n\n- [ ] Weight\n- [ ] Coffee\n"
        // Home carried over "Book parking", added last night; the train's
        // copy was made before that synced.
        let home = "- [ ] Book parking\n\n## Getting Up\n\n- [ ] Weight\n- [ ] Coffee\n"
        let train = "## Getting Up\n\n- [ ] Coffee\n"  // Weight ticked and decrufted
        let expected = "- [ ] Book parking\n\n## Getting Up\n\n- [ ] Coffee\n"
        #expect(merge(home, train, base: home, template: template) == expected)
        #expect(merge(home, train, template: template) == expected)
        #expect(merge(train, home, template: template) == expected)
        // Ticked rather than left alone on home: still decrufted on the train.
        let ticked = "- [ ] Book parking\n\n## Getting Up\n\n- [x] Weight\n- [ ] Coffee\n"
        #expect(merge(ticked, train, base: home, template: template) == expected)
    }

    @Test func repeatedTitlesAreMatchedInOrder() {
        let base = "- [ ] Morning\n  - [ ] Prayers\n- [ ] Evening\n  - [ ] Prayers\n"
        let a = "- [ ] Morning\n  - [x] Prayers\n- [ ] Evening\n  - [ ] Prayers\n"
        let b = "- [ ] Morning\n  - [ ] Prayers\n- [ ] Evening\n  - [x] Prayers\n"
        #expect(merge(a, b, base: base) == "- [ ] Morning\n  - [x] Prayers\n- [ ] Evening\n  - [x] Prayers\n")
    }

    @Test func sameVersionsMergeToThemselves() {
        let a = outline(made)
        #expect(RepeatingChecklists.mergeVersions(a, outline(made), base: a) == a)
    }

    @Test func clashingSavesOfACopyMergeByTask() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CopyMergeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkdownFileStore(fileURL: folder.appending(path: "Daily 2026-11-26.md"))
        let home = "- [ ] A\n- [x] B\n- [ ] C\n- [x] D\n"
        try store.writeText(home)
        let mine = "- [x] A\n- [ ] B\n- [x] C\n- [ ] D\n- [ ] E\n"
        let outcome = try FileSync.save(mine, to: store, synced: "- [ ] A\n- [ ] B\n- [ ] C\n- [ ] D\n") { mine, theirs in
            merge(mine, theirs, base: "- [ ] A\n- [ ] B\n- [ ] C\n- [ ] D\n", aIsMine: true)
        }
        let expected = "- [x] A\n- [x] B\n- [x] C\n- [x] D\n- [ ] E\n"
        #expect(outcome == .merged(expected))
        #expect(try store.readText() == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Daily 2026-11-26.md"])
    }
}

@Suite struct CopyMakerTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CopyMakerTests-\(UUID().uuidString)")
    var lists: TaskLibrary { TaskLibrary(folderURL: folder) }
    var templates: TaskLibrary { TaskLibrary(folderURL: lists.templatesFolderURL) }
    let home = RepeatingDevice(id: "home", name: "Home Mac")

    private func makeTemplate(_ name: String, maker: RepeatingDevice?) throws {
        try FileManager.default.createDirectory(at: templates.folderURL, withIntermediateDirectories: true)
        try templates.createList(named: name, contents: Outline(
            title: name, items: [TaskItem(title: "Stretch")], schedule: RepeatSchedule(frequency: .daily, maker: maker)))
    }

    private func run(as device: String) -> [String] {
        RepeatingChecklists.makeDueCopies(
            templates: templates, lists: lists, date: Date(timeIntervalSince1970: 1_795_000_000),
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_GB"), deviceID: device)
            .compactMap(\.copy).map(TaskLibrary.displayName(of:)).map { String($0.prefix(while: { $0 != " " })) }
    }

    @Test func eachTemplatesMakerAloneMakesItsCopies() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeTemplate("Daily", maker: home)
        try makeTemplate("Weekend", maker: nil)
        #expect(run(as: "laptop") == ["Weekend"])
        #expect(run(as: "home") == ["Daily"])
    }

    @Test func theMakerIsKeptInTheTemplatesMarker() {
        let schedule = RepeatSchedule(frequency: .daily, carriesOver: true, maker: RepeatingDevice(id: "AB-12", name: "Chris's Mac: Home"))
        let text = MarkdownCodec.encode(Outline(title: "Daily", items: [TaskItem(title: "Stretch")], schedule: schedule))
        #expect(text == "# Daily\n<!-- listful: repeat=daily carry-over made-on=AB-12:Chris%27s%20Mac%3A%20Home -->\n\n- [ ] Stretch\n")
        #expect(MarkdownCodec.decode(text).schedule?.maker == schedule.maker)
        #expect(MarkdownCodec.decode(text).schedule == schedule)
    }

    @Test func madeCopiesKeepsTheNewest() {
        var made = MadeCopies()
        for n in 0..<(MadeCopies.limit + 5) {
            made.record("text \(n)", name: "Daily \(n)", made: Date(timeIntervalSince1970: Double(n)))
        }
        #expect(made.entries.count == MadeCopies.limit)
        #expect(made.texts["Daily 0"] == nil)
        #expect(made.texts["Daily \(MadeCopies.limit + 4)"] == "text \(MadeCopies.limit + 4)")
    }
}

@Suite struct DuplicateConflictCopyTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ConflictCopyTests-\(UUID().uuidString)")
    var lists: TaskLibrary { TaskLibrary(folderURL: folder) }

    @Test func identicalDuplicatesOfConflictCopiesAreTrashed() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws { try MarkdownFileStore(fileURL: lists.url(forName: name)).writeText(text) }
        try write("Signet", "- [ ] now\n")
        try write("Signet (conflict 2026-11-26 22-58)", "- [ ] then\n")
        try write("Signet (conflict 2026-11-26 22-58) 2", "- [ ] then\n")
        try write("Signet (conflict 2026-11-26 23-10)", "- [ ] other\n")
        try write("Signet (conflict 2026-11-26 23-10) 2", "- [ ] different\n")
        try write("Signet 2", "- [ ] now\n")  // not a conflict copy: left alone
        let trashed = RepeatingChecklists.trashDuplicateConflictCopies(in: lists).map(TaskLibrary.displayName(of:))
        #expect(trashed == ["Signet (conflict 2026-11-26 22-58) 2"])
        #expect(try lists.lists().count == 5)
    }
}
