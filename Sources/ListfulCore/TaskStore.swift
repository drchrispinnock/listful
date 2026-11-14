import Foundation

/// A place an outline is loaded from and saved to. Local Markdown is the
/// first backend; git-backed Markdown and Apple Notes are planned.
public protocol TaskStore: Sendable {
    func load() throws -> Outline
    func save(_ outline: Outline) throws
}

public enum MarkdownFileStoreError: LocalizedError, Equatable {
    /// The file is in iCloud but not on this device yet; a download has been asked for.
    case notDownloaded(String)

    public var errorDescription: String? {
        switch self {
        case .notDownloaded(let name):
            "“\(name)” hasn't been downloaded from iCloud yet."
        }
    }
}

/// Stores the outline as a Markdown file on the local filesystem.
///
/// Reads and writes go through `NSFileCoordinator`, as iCloud Drive expects:
/// a coordinated read of a file that's only in iCloud (on macOS, a
/// "dataless" file left by Optimize Mac Storage) waits for it to download,
/// and a coordinated write tells the sync engine about the change. Both can
/// therefore take a while; call them off the main thread where it matters.
public struct MarkdownFileStore: TaskStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A missing file loads as an empty outline.
    public func load() throws -> Outline {
        try readText().map(MarkdownCodec.decode) ?? Outline()
    }

    public func save(_ outline: Outline) throws {
        try writeText(MarkdownCodec.encode(outline))
    }

    /// Whether the file is in iCloud but its contents aren't on this device,
    /// so reading it means waiting for a download.
    public var needsDownload: Bool {
        if TaskLibrary.placeholderExists(for: fileURL) { return true }
        // Fresh URL, so the answer isn't a cached resource value.
        let url = URL(fileURLWithPath: fileURL.path)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus
        else { return false }
        return status == .notDownloaded
    }

    /// The file's text, or nil if it doesn't exist. Used to spot changes
    /// made elsewhere since it was last read or written.
    ///
    /// A file that iCloud has only as a placeholder (`.Name.md.icloud`, as
    /// iOS keeps them) is *not* missing: this starts its download and throws
    /// `notDownloaded`, so nobody mistakes it for an empty list and writes
    /// over it.
    public func readText() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if TaskLibrary.placeholderExists(for: fileURL) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                throw MarkdownFileStoreError.notDownloaded(fileURL.lastPathComponent)
            }
            return nil
        }
        var result: Result<String?, Error> = .success(nil)
        try coordinate { coordinator, error in
            coordinator.coordinate(readingItemAt: fileURL, options: [], error: error) { url in
                // It may have gone while waiting for coordination.
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                result = Result { try String(contentsOf: url, encoding: .utf8) }
            }
        }
        return try result.get()
    }

    public func writeText(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var result: Result<Void, Error> = .success(())
        try coordinate { coordinator, error in
            coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: error) { url in
                result = Result { try text.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
        try result.get()
    }

    private func coordinate(_ body: (NSFileCoordinator, NSErrorPointer) -> Void) throws {
        var coordinationError: NSError?
        body(NSFileCoordinator(filePresenter: nil), &coordinationError)
        if let coordinationError { throw coordinationError }
    }
}
