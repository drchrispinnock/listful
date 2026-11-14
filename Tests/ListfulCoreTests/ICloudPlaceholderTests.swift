import Foundation
import Testing
@testable import ListfulCore

/// Files iCloud hasn't downloaded yet, kept as `.Name.md.icloud` placeholders.
@Suite struct ICloudPlaceholderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ICloudPlaceholderTests-\(UUID().uuidString)")
    var library: TaskLibrary { TaskLibrary(folderURL: folder) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    func makePlaceholder(for name: String) throws {
        try library.ensureFolderExists()
        try Data().write(to: TaskLibrary.placeholderURL(for: library.url(forName: name)))
    }

    @Test func placeholderNames() {
        let url = URL(fileURLWithPath: "/x/Shopping.md")
        #expect(TaskLibrary.placeholderURL(for: url).lastPathComponent == ".Shopping.md.icloud")
        #expect(TaskLibrary.realName(ofPlaceholder: ".Shopping.md.icloud") == "Shopping.md")
        #expect(TaskLibrary.realName(ofPlaceholder: "Shopping.md") == nil)
        #expect(TaskLibrary.realName(ofPlaceholder: "..icloud") == nil)
    }

    @Test func placeholdersAreListedUnderTheirRealNames() throws {
        defer { cleanUp() }
        try makePlaceholder(for: "b")
        try library.createList(named: "a")
        try Data().write(to: folder.appending(path: ".notes.txt.icloud"))
        try Data().write(to: folder.appending(path: "..hidden.md.icloud"))

        #expect(try library.lists() == [library.url(forName: "a"), library.url(forName: "b")])
    }

    @Test func aFileAndItsPlaceholderAreListedOnce() throws {
        defer { cleanUp() }
        try library.createList(named: "a")
        try makePlaceholder(for: "a")
        #expect(try library.lists() == [library.url(forName: "a")])
    }

    @Test func placeholdersTakeTheirNames() throws {
        defer { cleanUp() }
        try makePlaceholder(for: "Untitled")
        #expect(library.suggestedNewName() == "Untitled 2")
        #expect(throws: TaskLibraryError.alreadyExists("Untitled")) {
            try library.createList(named: "Untitled")
        }
        let other = try library.createList(named: "Other")
        #expect(throws: TaskLibraryError.alreadyExists("Untitled")) {
            try library.renameList(at: other, to: "Untitled")
        }
    }

    @Test func readingAPlaceholderThrowsRatherThanLookingEmpty() throws {
        defer { cleanUp() }
        try makePlaceholder(for: "Shopping")
        let store = MarkdownFileStore(fileURL: library.url(forName: "Shopping"))
        #expect(store.needsDownload)
        #expect(throws: MarkdownFileStoreError.notDownloaded("Shopping.md")) { try store.readText() }
        #expect(throws: MarkdownFileStoreError.notDownloaded("Shopping.md")) { try store.load() }
    }

    @Test func trashingAnUndownloadedListTrashesItsPlaceholder() throws {
        defer { cleanUp() }
        try makePlaceholder(for: "Shopping")
        try library.trashList(at: library.url(forName: "Shopping"))
        #expect(try library.lists().isEmpty)
    }

    @Test func coordinatedReadsAndWritesRoundTrip() throws {
        defer { cleanUp() }
        let store = MarkdownFileStore(fileURL: library.url(forName: "List"))
        #expect(try store.readText() == nil)
        #expect(!store.needsDownload)
        try store.writeText("- [ ] One\n")
        #expect(try store.readText() == "- [ ] One\n")
        try store.writeText("- [x] One\n")
        #expect(try store.readText() == "- [x] One\n")
    }

    @Test func renameMovesTheFile() throws {
        defer { cleanUp() }
        let url = try library.createList(named: "Old")
        let renamed = try library.renameList(at: url, to: "New")
        #expect(try library.lists() == [renamed])
        _ = try library.renameList(at: renamed, to: "new")
        #expect(try library.lists().map(\.lastPathComponent) == ["new.md"])
    }
}
