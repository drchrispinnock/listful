import Foundation

/// Reads and writes an `Outline` as a Markdown task list:
///
///     # Groceries
///
///     - [ ] Open task <!-- listful: collapsed -->
///       - [x] Done child
///       - [x] Tidied-away child <!-- listful: decrufted -->
///
///     ## Later
///
///     - [ ] Another task
///
/// A `#` heading on the first line is the list's title. Other `#`, `##` and
/// `###` lines at the left margin are headings. Nesting is two spaces per
/// level. State the checkbox can't express (decrufted, collapsed) goes in a
/// trailing HTML comment, which Markdown renderers hide. Other lines that
/// aren't list items become open tasks so that nothing in a hand-edited file
/// is lost.
public enum MarkdownCodec {
    static let indentUnit = "  "
    static let markerPrefix = "<!-- listful:"
    /// Written by versions from before the app was renamed; still read.
    static let legacyMarkerPrefixes = ["<!-- taskmgr:"]
    static let markerSuffix = "-->"
    static let tabWidth = 4

    public static func encode(_ outline: Outline) -> String {
        var lines: [String] = []
        var previousWasHeading = false

        if let title = outline.title {
            lines.append(headingLine(level: 1, title: title))
            previousWasHeading = true
        }

        for (i, item) in outline.items.enumerated() {
            var line: String
            var flags: [String] = []
            if let level = item.headingLevel {
                // Blank lines around headings, as Markdown is usually written.
                if !lines.isEmpty { lines.append("") }
                line = headingLine(level: level, title: item.title)
            } else {
                if previousWasHeading { lines.append("") }
                line = String(repeating: indentUnit, count: item.depth)
                line += item.state == .open ? "- [ ] " : "- [x] "
                line += item.title
                if item.state == .decrufted { flags.append("decrufted") }
            }
            if item.isCollapsed && outline.canCollapse(i) { flags.append("collapsed") }
            if !flags.isEmpty {
                line += " \(markerPrefix) \(flags.joined(separator: " ")) \(markerSuffix)"
            }
            lines.append(line)
            previousWasHeading = item.isHeading
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func decode(_ text: String) -> Outline {
        var title: String?
        var items: [TaskItem] = []
        var sawContent = false
        // Indent widths of the current chain of ancestors.
        var indentStack: [Int] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let (indent, content) = splitIndent(rawLine)
            var rest = content.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }

            let flags = takeMarker(from: &rest) ?? []
            let isFirstLine = !sawContent
            sawContent = true

            if indent == 0, let heading = parseHeading(rest) {
                if isFirstLine && heading.level == 1 {
                    title = heading.text
                    continue
                }
                items.append(TaskItem(
                    title: heading.text,
                    isCollapsed: flags.contains("collapsed"),
                    headingLevel: heading.level
                ))
                // Tasks after a heading start again at the top level.
                indentStack.removeAll()
                continue
            }

            while let last = indentStack.last, last >= indent { indentStack.removeLast() }
            let depth = indentStack.count
            indentStack.append(indent)

            var state = flags.contains("decrufted") ? TaskState.decrufted : .open
            if let bulletless = dropBullet(rest) {
                rest = bulletless
                if let (checked, title) = dropCheckbox(rest) {
                    rest = title
                    if checked && state != .decrufted { state = .done }
                    if !checked { state = .open }
                }
            }

            items.append(TaskItem(title: rest, state: state, depth: depth, isCollapsed: flags.contains("collapsed")))
        }
        return Outline(title: title, items: items)
    }

    /// The list title a file would decode to, without decoding the rest.
    public static func title(in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let (indent, content) = splitIndent(rawLine)
            var rest = content.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            _ = takeMarker(from: &rest)
            guard indent == 0, let heading = parseHeading(rest), heading.level == 1 else { return nil }
            return heading.text
        }
        return nil
    }

    /// Parses an ATX heading of level 1–3 (`# Title`, `## Title ##`).
    /// Deeper levels aren't headings here. `#tag` (no space) isn't a heading.
    public static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##".
        if let closing = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = text[..<closing.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    static func headingLine(level: Int, title: String) -> String {
        let hashes = String(repeating: "#", count: level)
        return title.isEmpty ? hashes : "\(hashes) \(title)"
    }

    // MARK: - Line parsing

    private static func splitIndent(_ line: Substring) -> (width: Int, rest: Substring) {
        var width = 0
        var index = line.startIndex
        while index < line.endIndex {
            switch line[index] {
            case " ": width += 1
            case "\t": width += tabWidth - width % tabWidth
            default: return (width, line[index...])
            }
            index = line.index(after: index)
        }
        return (width, line[index...])
    }

    /// Strips a trailing `<!-- listful: ... -->` comment and returns its words.
    private static func takeMarker(from text: inout String) -> Set<String>? {
        let line = text
        guard line.hasSuffix(markerSuffix),
              let start = ([markerPrefix] + legacyMarkerPrefixes)
                .compactMap({ line.range(of: $0, options: .backwards) })
                .max(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let body = text[start.upperBound..<text.index(text.endIndex, offsetBy: -markerSuffix.count)]
        let flags = Set(body.split(whereSeparator: \.isWhitespace).map(String.init))
        text = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
        return flags
    }

    private static func dropBullet(_ text: String) -> String? {
        for bullet in ["- ", "* ", "+ "] where text.hasPrefix(bullet) {
            return String(text.dropFirst(bullet.count))
        }
        return ["-", "*", "+"].contains(text) ? "" : nil
    }

    private static func dropCheckbox(_ text: String) -> (checked: Bool, title: String)? {
        for (box, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] {
            if text == box { return (checked, "") }
            if text.hasPrefix(box + " ") { return (checked, String(text.dropFirst(box.count + 1))) }
        }
        return nil
    }
}
