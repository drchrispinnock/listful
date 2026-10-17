import Foundation

/// A place an outline is loaded from and saved to. Local Markdown is the
/// first backend; git-backed Markdown and Apple Notes are planned.
public protocol TaskStore: Sendable {
    func load() throws -> Outline
    func save(_ outline: Outline) throws
}

/// Stores the outline as a Markdown file on the local filesystem.
public struct MarkdownFileStore: TaskStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A missing file loads as an empty outline.
    public func load() throws -> Outline {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Outline() }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return MarkdownCodec.decode(text)
    }

    public func save(_ outline: Outline) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try MarkdownCodec.encode(outline).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
