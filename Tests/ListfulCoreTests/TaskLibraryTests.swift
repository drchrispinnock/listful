import Foundation
import Testing
@testable import ListfulCore

@Suite struct TaskLibraryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "TaskLibraryTests-\(UUID().uuidString)")
    var library: TaskLibrary { TaskLibrary(folderURL: folder) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func listsOnlyMarkdownFilesSortedLikeFinder() throws {
        defer { cleanUp() }
        try library.ensureFolderExists()
        for name in ["b.md", "a 10.md", "a 2.md", "notes.txt", ".hidden.md", "Upper.MD"] {
            try "".write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "dir.md"), withIntermediateDirectories: false)

        let names = try library.lists().map(TaskLibrary.displayName(of:))
        #expect(names == ["a 2", "a 10", "b", "Upper"])
    }

    @Test func listURLsMatchCreatedURLs() throws {
        defer { cleanUp() }
        let created = try library.createList(named: "Groceries")
        #expect(try library.lists() == [created])
    }

    @Test func containsMatchesFolderFilesThroughSymlinks() throws {
        defer { cleanUp() }
        try library.ensureFolderExists()
        let link = FileManager.default.temporaryDirectory.appending(path: "TaskLibraryLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(library.contains(folder.appending(path: "a.md")))
        #expect(library.contains(link.appending(path: "a.md")))
        #expect(library.canonicalURL(for: link.appending(path: "a.md")) == library.url(forName: "a"))
        #expect(!library.contains(folder.appending(path: "a.txt")))
        #expect(!library.contains(folder.appending(path: "sub/a.md")))
        #expect(!library.contains(FileManager.default.temporaryDirectory.appending(path: "a.md")))
    }

    @Test func createValidatesAndRejectsDuplicates() throws {
        defer { cleanUp() }
        let url = try library.createList(named: "  Work.md ")
        #expect(url.lastPathComponent == "Work.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "")

        #expect(throws: TaskLibraryError.alreadyExists("Work")) { try library.createList(named: "Work") }
        for bad in ["", "   ", ".secret", "a/b", "a:b"] {
            #expect(throws: TaskLibraryError.invalidName) { try library.createList(named: bad) }
        }
    }

    @Test func suggestedNameSkipsTakenNames() throws {
        defer { cleanUp() }
        #expect(library.suggestedNewName() == "Untitled")
        try library.createList(named: "Untitled")
        try library.createList(named: "Untitled 2")
        #expect(library.suggestedNewName() == "Untitled 3")
    }

    @Test func renameMovesFileAndRejectsClashes() throws {
        defer { cleanUp() }
        let home = try library.createList(named: "Home")
        try library.createList(named: "Work")

        #expect(throws: TaskLibraryError.alreadyExists("Work")) { try library.renameList(at: home, to: "Work") }

        let renamed = try library.renameList(at: home, to: "House")
        #expect(try library.lists().map(TaskLibrary.displayName(of:)) == ["House", "Work"])

        let recased = try library.renameList(at: renamed, to: "house")
        #expect(try library.lists().map(TaskLibrary.displayName(of:)) == ["house", "Work"])
        #expect(recased.lastPathComponent == "house.md")
    }
}
