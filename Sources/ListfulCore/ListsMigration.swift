import Foundation

#if os(macOS)

/// Moving the task lists from the Mac's old default folder,
/// `~/Documents/Task Lists`, to the app's own folder in iCloud Drive
/// (iCloud Drive › Listful, which the iPhone and iPad app use).
///
/// The iCloud folder is the container `iCloud.com.chrispinnock.listful`.
/// The iOS app creates it; iCloud then brings it to every Mac on the same
/// account at `~/Library/Mobile Documents/iCloud~com~chrispinnock~listful`.
/// The Mac app isn't sandboxed and has no iCloud entitlement, so it uses
/// that path directly and never creates the container itself (an
/// unregistered folder there wouldn't sync).
public enum ListsMigration {
    public static let iCloudContainerFolderName = "iCloud~com~chrispinnock~listful"

    /// The app's iCloud Drive folder on this Mac (it may not exist yet).
    public static func iCloudFolderURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Mobile Documents/\(iCloudContainerFolderName)/Documents", directoryHint: .isDirectory)
    }

    /// Where the lists were kept before 0.6.
    public static func legacyFolderURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Documents/Task Lists", directoryHint: .isDirectory)
    }

    /// Whether iCloud has brought the container to this Mac. Its `Documents`
    /// folder may not be there yet; `move` creates it.
    public static func iCloudContainerExists(at folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public enum Plan: Equatable, Sendable {
        /// The iCloud folder isn't on this Mac (yet): stay where we are.
        case none
        /// Nothing to move (another Mac has already moved the lists, or there
        /// never were any): just use the iCloud folder.
        case switchOnly
        /// The old folder has lists to move.
        case move
    }

    public static func plan(from old: URL, to new: URL) -> Plan {
        guard iCloudContainerExists(at: new) else { return .none }
        return contents(of: old).isEmpty ? .switchOnly : .move
    }

    /// Moves everything in `old` (lists, subfolders, Templates) into `new`,
    /// with coordinated moves so iCloud keeps track (files not downloaded to
    /// this Mac move without downloading). Where `new` already has an item
    /// of the same name, folders are merged, identical files dropped from
    /// `old`, and differing files kept under a new name. `old` is trashed if
    /// it ends up empty. Returns the files that had to be renamed, as
    /// (original name, new name) relative paths.
    @discardableResult
    public static func move(from old: URL, to new: URL,
                            trash: (URL) throws -> Void = coordinatedTrash) throws -> [(String, String)] {
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        var renamed: [(String, String)] = []
        try merge(old, into: new, relativePath: "", renamed: &renamed, trash: trash)
        if contents(of: old).isEmpty {
            try? trash(old)
        }
        return renamed
    }

    private static func merge(_ source: URL, into destinationFolder: URL, relativePath: String,
                              renamed: inout [(String, String)], trash: (URL) throws -> Void) throws {
        for item in contents(of: source) {
            let name = item.lastPathComponent
            let target = destinationFolder.appending(path: name, directoryHint: isDirectory(item) ? .isDirectory : .notDirectory)
            let path = relativePath + name
            guard FileManager.default.fileExists(atPath: target.path) else {
                try coordinatedMove(item, to: target)
                continue
            }
            if isDirectory(item) && isDirectory(target) {
                try merge(item, into: target, relativePath: path + "/", renamed: &renamed, trash: trash)
                if contents(of: item).isEmpty { try? trash(item) }
            } else if !isDirectory(item), !isDirectory(target), sameContents(item, target) {
                try trash(item)
            } else {
                let free = freeName(for: name, in: destinationFolder)
                try coordinatedMove(item, to: destinationFolder.appending(path: free))
                renamed.append((path, relativePath + free))
            }
        }
    }

    /// `Name 2.md`, `Name 3.md`, … : the first not taken.
    static func freeName(for name: String, in folder: URL) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !FileManager.default.fileExists(atPath: folder.appending(path: candidate).path) { return candidate }
            n += 1
        }
    }

    /// Visible items: not `.DS_Store` and the like.
    static func contents(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let left = try? coordinatedRead(a), let right = try? coordinatedRead(b) else { return false }
        return left == right
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func coordinatedMove(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
    }

    /// Moves to the Trash, coordinated.
    public static func coordinatedTrash(_ url: URL) throws {
        var coordinationError: NSError?
        var trashError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { trashError = error }
        }
        if let error = coordinationError ?? trashError { throw error }
    }
}
#endif
