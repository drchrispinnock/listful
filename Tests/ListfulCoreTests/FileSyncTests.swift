import Foundation
import Testing
@testable import ListfulCore

@Suite struct FileSyncTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FileSyncTests-\(UUID().uuidString)")
    var store: MarkdownFileStore { MarkdownFileStore(fileURL: folder.appending(path: "List.md")) }

    func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func newFileIsWritten() throws {
        defer { cleanUp() }
        let outcome = try FileSync.save("- [ ] a\n", to: store, synced: nil)
        #expect(outcome == .saved("- [ ] a\n"))
        #expect(try store.readText() == "- [ ] a\n")
    }

    @Test func unchangedFileIsOverwritten() throws {
        defer { cleanUp() }
        try store.writeText("- [ ] a\n")
        let outcome = try FileSync.save("- [x] a\n", to: store, synced: "- [ ] a\n")
        #expect(outcome == .saved("- [x] a\n"))
        #expect(try store.readText() == "- [x] a\n")
    }

    @Test func changesOnBothSidesMerge() throws {
        defer { cleanUp() }
        let base = "- [ ] a\n- [ ] b\n"
        try store.writeText("- [ ] a\n- [x] b\n")  // ticked elsewhere
        let outcome = try FileSync.save("- [x] a\n- [ ] b\n", to: store, synced: base)
        #expect(outcome == .merged("- [x] a\n- [x] b\n"))
        #expect(try store.readText() == "- [x] a\n- [x] b\n")
    }

    @Test func clashKeepsTheirsAndCopiesMine() throws {
        defer { cleanUp() }
        try store.writeText("- [ ] theirs\n")
        let date = Date(timeIntervalSince1970: 0)
        let outcome = try FileSync.save("- [ ] mine\n", to: store, synced: "- [ ] base\n", date: date)
        guard case .conflict(let disk, let copy) = outcome else {
            Issue.record("expected a conflict, got \(outcome)")
            return
        }
        #expect(disk == "- [ ] theirs\n")
        #expect(try store.readText() == "- [ ] theirs\n")
        #expect(try MarkdownFileStore(fileURL: copy).readText() == "- [ ] mine\n")
    }

    @Test func goneFileIsNeverRecreated() throws {
        defer { cleanUp() }
        let unchanged = try FileSync.save("- [ ] a\n", to: store, synced: "- [ ] a\n")
        #expect(unchanged == .gone(copy: nil))
        #expect(try store.readText() == nil)

        let edited = try FileSync.save("- [ ] b\n", to: store, synced: "- [ ] a\n")
        guard case .gone(let copy?) = edited else {
            Issue.record("expected a copy, got \(edited)")
            return
        }
        #expect(try store.readText() == nil)
        #expect(try MarkdownFileStore(fileURL: copy).readText() == "- [ ] b\n")
    }
}
