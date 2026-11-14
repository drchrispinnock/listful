import Foundation
import Testing
@testable import ListfulCore

@Suite struct SubfolderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SubfolderTests-\(UUID().uuidString)")
    var library: TaskLibrary { TaskLibrary(folderURL: folder) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func subfoldersSkipTemplatesHiddenFoldersAndPackages() throws {
        defer { cleanUp() }
        try library.ensureFolderExists()
        for name in ["Work 10", "Work 2", "Templates", ".git", "Thing.app"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        try library.createList(named: "List")
        #expect(try library.subfolders().map(\.lastPathComponent) == ["Work 2", "Work 10"])
    }

    @Test func subfolderURLsAreStableAndListTheirFiles() throws {
        defer { cleanUp() }
        let work = try library.createFolder(named: "Work")
        #expect(try library.subfolders() == [work])
        let inside = TaskLibrary(folderURL: work)
        let list = try inside.createList(named: "Plan")
        #expect(try inside.lists() == [list])
        #expect(try TaskLibrary(folderURL: try library.subfolders()[0]).lists() == [list])
        #expect(try library.lists().isEmpty)
    }

    @Test func createAndRenameRejectClashes() throws {
        defer { cleanUp() }
        let work = try library.createFolder(named: "Work")
        #expect(throws: TaskLibraryError.alreadyExists("Work")) { try library.createFolder(named: "Work") }
        #expect(throws: TaskLibraryError.invalidName) { try library.createFolder(named: "a/b") }
        try library.createFolder(named: "Home")
        #expect(throws: TaskLibraryError.alreadyExists("Home")) { try library.renameFolder(at: work, to: "Home") }
        #expect(throws: TaskLibraryError.alreadyExists("Templates")) { try library.renameFolder(at: work, to: "Templates") }

        try TaskLibrary(folderURL: work).createList(named: "Plan")
        let renamed = try library.renameFolder(at: work, to: "Office")
        #expect(try library.subfolders().map(\.lastPathComponent) == ["Home", "Office"])
        #expect(try TaskLibrary(folderURL: renamed).lists().map(\.lastPathComponent) == ["Plan.md"])
        let caseOnly = try library.renameFolder(at: renamed, to: "office")
        #expect(caseOnly.lastPathComponent == "office")
    }

    @Test func folderNamesAreTakenForNewLists() throws {
        defer { cleanUp() }
        try library.createFolder(named: "Untitled")
        #expect(library.suggestedNewName() == "Untitled 2")
    }

    @Test func trashingAFolderRemovesIt() throws {
        defer { cleanUp() }
        let work = try library.createFolder(named: "Work")
        try TaskLibrary(folderURL: work).createList(named: "Plan")
        try library.trashFolder(at: work)
        #expect(try library.subfolders().isEmpty)
    }
}
