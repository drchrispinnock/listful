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
        while fileExists(folder.appending(path: name + "." + fileExtension)) {
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

    /// Where repeating checklists' templates are kept: a subfolder, so they
    /// aren't listed among the lists themselves.
    public var templatesFolderURL: URL {
        folderURL.appending(path: "Templates")
    }

    public func ensureFolderExists() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    /// The `.md` files in the folder, sorted by name the way Finder does.
    /// URLs are rebuilt from `folderURL` so they compare equal to ones from
    /// `url(forName:)`. A file iCloud hasn't downloaded yet counts, under its
    /// real name, even where only its placeholder is on disk.
    public func lists() throws -> [URL] {
        var names = Set<String>()
        for url in try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil) {
            guard !url.hasDirectoryPath else { continue }
            let name = Self.realName(ofPlaceholder: url.lastPathComponent) ?? url.lastPathComponent
            guard !name.hasPrefix("."), (name as NSString).pathExtension.lowercased() == Self.fileExtension else { continue }
            names.insert(name)
        }
        return names
            .map { folderURL.appending(path: $0) }
            .sorted { Self.displayName(of: $0).localizedStandardCompare(Self.displayName(of: $1)) == .orderedAscending }
    }

    // MARK: - iCloud placeholders

    /// Where iCloud keeps the stand-in for `url` while the file itself isn't
    /// on this device: `.Name.md.icloud` beside it. (iOS does this; macOS 14+
    /// keeps "dataless" files under their real names instead.)
    public static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent + ".icloud")
    }

    /// The file name a placeholder stands in for, or nil if `name` isn't one.
    public static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return real.isEmpty ? nil : real
    }

    public static func placeholderExists(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// Whether a file is at `url`, downloaded or not. Use this rather than
    /// `FileManager.fileExists` before claiming a name.
    public static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || placeholderExists(for: url)
    }

    // MARK: - Subfolders

    /// The folders directly inside this one that hold lists of their own,
    /// sorted like Finder: every visible subfolder except Templates. URLs
    /// are rebuilt from `folderURL`, with a trailing slash, so they compare
    /// equal across calls.
    public func subfolders() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                 options: [.skipsHiddenFiles])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
                    && url.lastPathComponent != templatesFolderURL.lastPathComponent
            }
            .map { folderURL(named: $0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func folderURL(named name: String) -> URL {
        folderURL.appending(path: name, directoryHint: .isDirectory)
    }

    @discardableResult
    public func createFolder(named rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName, keepingExtension: true)
        let url = folderURL(named: name)
        guard !Self.fileExists(url) else { throw TaskLibraryError.alreadyExists(name) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func renameFolder(at url: URL, to rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName, keepingExtension: true)
        guard name != templatesFolderURL.lastPathComponent else { throw TaskLibraryError.alreadyExists(name) }
        let destination = folderURL(named: name)
        guard destination.path != url.path else { return url }
        let isCaseChange = destination.path.lowercased() == url.path.lowercased()
        if !isCaseChange && Self.fileExists(destination) {
            throw TaskLibraryError.alreadyExists(name)
        }
        try Self.move(url, to: destination)
        return destination
    }

    /// Moves a subfolder, and every list in it, to the Trash.
    public func trashFolder(at url: URL) throws {
        try trashList(at: url)
    }

    /// "Untitled", or "Untitled 2", "Untitled 3"… if taken.
    public func suggestedNewName(base: String = "Untitled") -> String {
        var name = base
        var counter = 2
        while Self.fileExists(url(forName: name)) || Self.fileExists(folderURL(named: name)) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    @discardableResult
    public func createList(named rawName: String, contents: Outline = Outline()) throws -> URL {
        let name = try Self.validatedName(rawName)
        let url = url(forName: name)
        guard !Self.fileExists(url) else {
            throw TaskLibraryError.alreadyExists(name)
        }
        try ensureFolderExists()
        try MarkdownFileStore(fileURL: url).save(contents)
        return url
    }

    public func renameList(at url: URL, to rawName: String) throws -> URL {
        let name = try Self.validatedName(rawName)
        let destination = self.url(forName: name)
        guard destination != url else { return url }
        // Allow case-only renames, which the case-insensitive filesystem
        // would otherwise report as a clash with the file itself.
        let isCaseChange = destination.path.lowercased() == url.path.lowercased()
        if !isCaseChange && Self.fileExists(destination) {
            throw TaskLibraryError.alreadyExists(name)
        }
        try Self.move(url, to: destination)
        return destination
    }

    public func trashList(at url: URL) throws {
        // A list not yet downloaded is trashed as its placeholder.
        let target = FileManager.default.fileExists(atPath: url.path) || !Self.placeholderExists(for: url)
            ? url : Self.placeholderURL(for: url)
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil)
            .coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
                result = Result { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Moves a file with coordination, so iCloud sees a rename rather than a
    /// delete and a new file.
    static func move(_ source: URL, to destination: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            result = Result {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    static func validatedName(_ rawName: String, keepingExtension: Bool = false) throws -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keepingExtension, name.lowercased().hasSuffix("." + fileExtension) {
            name = String(name.dropLast(fileExtension.count + 1))
        }
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw TaskLibraryError.invalidName
        }
        return name
    }
}
