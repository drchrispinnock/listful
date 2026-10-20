import Foundation

public enum TaskLibraryError: LocalizedError, Equatable {
    case invalidName
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "A task list name can't be empty, start with a dot, or contain “/” or “:”."
        case .alreadyExists(let name):
            "A task list called “\(name)” already exists."
        }
    }
}

/// A folder of task lists, one Markdown file per list. List names are the
/// file names without the `.md` extension.
public struct TaskLibrary: Sendable {
    public static let fileExtension = "md"

    public let folderURL: URL

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    public static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Where to keep this Mac's version of a list when it clashes with
    /// changes made elsewhere: beside it, as "Name (conflict 2026-10-19 14-05).md",
    /// numbered if that's taken.
    public static func conflictCopyURL(for url: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "\(displayName(of: url)) (conflict \(formatter.string(from: date)))"
        let folder = url.deletingLastPathComponent()
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appending(path: name + "." + fileExtension).path) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return folder.appending(path: name).appendingPathExtension(fileExtension)
    }

    public func url(forName name: String) -> URL {
        folderURL.appending(path: name).appendingPathExtension(Self.fileExtension)
    }

    /// Whether `url` is a list directly inside this folder, comparing real
    /// paths so that symlinked spellings (e.g. /tmp vs /private/tmp) match.
    public func contains(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let folder = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
        return parent == folder && url.pathExtension.lowercased() == Self.fileExtension
    }

    /// The `url(forName:)` spelling of a file inside this folder, so it matches `lists()`.
    public func canonicalURL(for url: URL) -> URL {
        folderURL.appending(path: url.lastPathComponent)
    }

    public func ensureFolderExists() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    /// The `.md` files in the folder, sorted by name the way Finder does.
    /// URLs are rebuilt from `folderURL` so they compare equal to ones from
    /// `url(forName:)`.
    public func lists() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == Self.fileExtension && !$0.hasDirectoryPath }
            .map { folderURL.appending(path: $0.lastPathComponent) }
            .sorted { Self.displayName(of: $0).localizedStandardCompare(Self.displayName(of: $1)) == .orderedAscending }
    }

    /// "Untitled", or "Untitled 2", "Untitled 3"… if taken.
    public func suggestedNewName(base: String = "Untitled") -> String {
        var name = base
        var counter = 2
        while FileManager.default.fileExists(atPath: url(forName: name).path) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    @discardableResult
    public func createList(named rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName)
        let url = url(forName: name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw TaskLibraryError.alreadyExists(name)
        }
        try ensureFolderExists()
        try MarkdownFileStore(fileURL: url).save(Outline())
        return url
    }

    public func renameList(at url: URL, to rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName)
        let destination = self.url(forName: name)
        guard destination != url else { return url }
        // Allow case-only renames, which the case-insensitive filesystem
        // would otherwise report as a clash with the file itself.
        let isCaseChange = destination.path.lowercased() == url.path.lowercased()
        if !isCaseChange && FileManager.default.fileExists(atPath: destination.path) {
            throw TaskLibraryError.alreadyExists(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    public func trashList(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    static func validatedName(_ rawName: String) throws -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix("." + fileExtension) {
            name = String(name.dropLast(fileExtension.count + 1))
        }
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw TaskLibraryError.invalidName
        }
        return name
    }
}
