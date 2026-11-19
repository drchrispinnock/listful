import Foundation

/// How copied rows are written to and read from the clipboard. Rows go up
/// in two forms: Listful's own Markdown, keeping everything (done,
/// decrufted, collapsed), and plain text for other apps, without Listful's
/// hidden markers. A single row on its own is copied as just its text, so
/// it pastes into a line of text as you'd expect.
public enum TaskClipboard {
    /// Listful's own pasteboard type.
    public static let typeIdentifier = "com.chrispinnock.listful.tasks"

    public static func markdown(_ block: [TaskItem]) -> String {
        MarkdownCodec.encode(Outline(items: block))
    }

    public static func plainText(_ block: [TaskItem]) -> String {
        if block.count == 1 { return block[0].title }
        return markdown(block)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let marker = line.range(of: " " + MarkdownCodec.markerPrefix) else { return String(line) }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// Rows from pasted text: Markdown list items, headings, or any other
    /// lines, one task each. Blank lines are dropped; a `#` line at the top
    /// is a heading here, not a list title.
    public static func items(from text: String) -> [TaskItem] {
        let outline = MarkdownCodec.decode(text, plainLinesAreTasks: true)
        var items = outline.items
        if let title = outline.title { items.insert(TaskItem(title: title, headingLevel: 1), at: 0) }
        return Outline(items: items.filter { $0.isHeading || !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }).items
    }
}
