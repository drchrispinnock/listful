import Foundation
import Testing
@testable import ListfulCore

@Suite struct ListsMigrationTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "ListsMigrationTests-\(UUID().uuidString)")
    var old: URL { root.appending(path: "Documents/Task Lists", directoryHint: .isDirectory) }
    /// Laid out like the real container: `<container>/Documents`.
    var container: URL { root.appending(path: "Mobile Documents/iCloud~com~chrispinnock~listful", directoryHint: .isDirectory) }
    var new: URL { container.appending(path: "Documents", directoryHint: .isDirectory) }

    /// Stands in for the Trash: removes the item, remembering its name.
    final class Bin { var names: [String] = [] }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String, in folder: URL) -> String? {
        try? String(contentsOf: folder.appending(path: path), encoding: .utf8)
    }

    func move(bin: Bin) throws -> [(String, String)] {
        try ListsMigration.move(from: old, to: new) { url in
            bin.names.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
    }

    @Test func pathsMatchTheMac() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(ListsMigration.iCloudFolderURL(home: home).path
            == "/Users/someone/Library/Mobile Documents/iCloud~com~chrispinnock~listful/Documents")
        #expect(ListsMigration.legacyFolderURL(home: home).path == "/Users/someone/Documents/Task Lists")
    }

    @Test func planWaitsForTheContainer() throws {
        defer { cleanUp() }
        try write("- [ ] a\n", "Inbox.md", in: old)
        #expect(ListsMigration.plan(from: old, to: new) == .none)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        #expect(ListsMigration.plan(from: old, to: new) == .move)
    }

    @Test func planSwitchesWhenThereIsNothingToMove() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        #expect(ListsMigration.plan(from: old, to: new) == .switchOnly)  // no old folder
        try write("", ".DS_Store", in: old)
        #expect(ListsMigration.plan(from: old, to: new) == .switchOnly)  // only hidden files
    }

    @Test func movesListsSubfoldersAndTemplatesThenTrashesTheOldFolder() throws {
        defer { cleanUp() }
        try write("- [ ] a\n", "Inbox.md", in: old)
        try write("- [ ] b\n", "Work/Plan.md", in: old)
        try write("- [ ] c\n", "Templates/Daily.md", in: old)
        try write("", ".DS_Store", in: old)
        let bin = Bin()
        let renamed = try move(bin: bin)
        #expect(renamed.isEmpty)
        #expect(read("Inbox.md", in: new) == "- [ ] a\n")
        #expect(read("Work/Plan.md", in: new) == "- [ ] b\n")
        #expect(read("Templates/Daily.md", in: new) == "- [ ] c\n")
        #expect(bin.names == ["Task Lists"])
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test func clashesMergeFoldersDropIdenticalFilesAndRenameDifferentOnes() throws {
        defer { cleanUp() }
        try write("- [ ] same\n", "Inbox.md", in: old)
        try write("- [ ] same\n", "Inbox.md", in: new)
        try write("- [ ] mac\n", "Work/Plan.md", in: old)
        try write("- [ ] phone\n", "Work/Plan.md", in: new)
        try write("- [ ] only mac\n", "Work/Notes.md", in: old)
        let bin = Bin()
        let renamed = try move(bin: bin)
        #expect(renamed.map(\.0) == ["Work/Plan.md"])
        #expect(renamed.map(\.1) == ["Work/Plan 2.md"])
        #expect(read("Inbox.md", in: new) == "- [ ] same\n")
        #expect(read("Work/Plan.md", in: new) == "- [ ] phone\n")
        #expect(read("Work/Plan 2.md", in: new) == "- [ ] mac\n")
        #expect(read("Work/Notes.md", in: new) == "- [ ] only mac\n")
        #expect(Set(bin.names) == ["Inbox.md", "Work", "Task Lists"])
    }
}
