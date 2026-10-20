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
        try readText().map(MarkdownCodec.decode) ?? Outline()
    }

    public func save(_ outline: Outline) throws {
        try writeText(MarkdownCodec.encode(outline))
    }

    /// The file's text, or nil if it doesn't exist. Used to spot changes
    /// made elsewhere since it was last read or written.
    public func readText() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    public func writeText(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
