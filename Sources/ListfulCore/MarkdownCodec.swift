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
/// A repeating checklist's template has its schedule in a marker line of its
/// own after the title (see `RepeatSchedule`).
/// A `#` heading on the first line is the list's title. Other `#`, `##` and
/// `###` lines at the left margin are headings. List items (`-`, `*` or `+`,
/// with or without a checkbox) are tasks; nesting is two spaces per level.
/// A trailing `{…}` attribute block on a task or heading (`## Setup
/// {#setup}`) is kept aside, not shown as part of its text. State the
/// checkbox can't express (decrufted, collapsed) goes in a trailing HTML
/// comment, which Markdown renderers hide.
///
/// Everything else (paragraphs, numbered lines, list items that are only an
/// attribute block) isn't a task: it's kept verbatim as the notes of the
/// item before it (`TaskItem.notes`, or `Outline.preamble` before the first
/// item), shown read-only and written back where it was, so nothing in a
/// hand-edited file is lost.
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
            lines.append(headingLine(level: 1, title: title, attributes: outline.titleAttributes))
            previousWasHeading = true
        }
        if let schedule = outline.schedule {
            lines.append("\(markerPrefix) \(schedule.markerWords.joined(separator: " ")) \(markerSuffix)")
        }
        if !outline.preamble.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += outline.preamble
            previousWasHeading = true  // a blank line before the first task
        }

        for (i, item) in outline.items.enumerated() {
            var line: String
            var flags: [String] = []
            if let level = item.headingLevel {
                // Blank lines around headings, as Markdown is usually written.
                if !lines.isEmpty { lines.append("") }
                line = headingLine(level: level, title: item.title, attributes: item.attributes)
            } else {
                if previousWasHeading { lines.append("") }
                line = String(repeating: indentUnit, count: item.depth)
                line += item.state == .open ? "- [ ] " : "- [x] "
                line += [item.title, item.attributes ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                if item.state == .decrufted { flags.append("decrufted") }
            }
            if item.isCollapsed && outline.canCollapse(i) { flags.append("collapsed") }
            if !flags.isEmpty {
                line += " \(markerPrefix) \(flags.joined(separator: " ")) \(markerSuffix)"
            }
            lines.append(line)
            previousWasHeading = item.isHeading
            if !item.notes.isEmpty {
                // A paragraph at the margin is set off by blank lines (else
                // Markdown would run it into the list item); indented notes
                // stay attached.
                let isParagraph = item.isHeading || !(item.notes[0].first?.isWhitespace ?? false)
                if isParagraph { lines.append("") }
                lines += item.notes
                previousWasHeading = isParagraph
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func decode(_ text: String) -> Outline {
        decode(text, plainLinesAreTasks: false)
    }

    /// With `plainLinesAreTasks` (pasted text), lines that aren't list
    /// items become tasks rather than notes.
    public static func decode(_ text: String, plainLinesAreTasks: Bool) -> Outline {
        var title: String?
        var titleAttributes: String?
        var schedule: RepeatSchedule?
        var items: [TaskItem] = []
        var preamble: [String] = []
        var sawContent = false
        var sawBlank = false
        // Indent widths of the current chain of ancestors.
        var indentStack: [Int] = []

        /// A line that isn't a task or heading: a note of the item before it.
        func addNote(_ line: Substring) {
            var raw = String(line)
            while raw.last?.isWhitespace == true { raw.removeLast() }
            func append(to notes: inout [String]) {
                if sawBlank && !notes.isEmpty { notes.append("") }
                notes.append(raw)
            }
            if items.isEmpty { append(to: &preamble) } else { append(to: &items[items.count - 1].notes) }
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let (indent, content) = splitIndent(rawLine)
            var rest = content.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else {
                sawBlank = true
                continue
            }
            defer { sawBlank = false }

            let flags = takeMarker(from: &rest) ?? []
            // A marker on a line of its own is the list's repeat schedule.
            if rest.isEmpty, schedule == nil, let parsed = RepeatSchedule(markerWords: flags) {
                schedule = parsed
                continue
            }
            let isFirstLine = !sawContent
            sawContent = true

            if indent == 0, let heading = parseHeading(rest) {
                let (text, attributes) = splitAttributes(heading.text)
                if isFirstLine && heading.level == 1 {
                    title = text
                    titleAttributes = attributes
                    continue
                }
                items.append(TaskItem(
                    title: text,
                    isCollapsed: flags.contains("collapsed"),
                    headingLevel: heading.level,
                    attributes: attributes
                ))
                // Tasks after a heading start again at the top level.
                indentStack.removeAll()
                continue
            }

            // Only list items are tasks, and not ones that are just `{…}`.
            guard var title = dropBullet(rest) ?? (plainLinesAreTasks ? rest : nil) else {
                addNote(rawLine)
                continue
            }
            var state = flags.contains("decrufted") ? TaskState.decrufted : .open
            if let (checked, text) = dropCheckbox(title) {
                title = text
                if checked && state != .decrufted { state = .done }
                if !checked { state = .open }
            }
            if isAttributeBlock(title) {
                addNote(rawLine)
                continue
            }
            let (text, attributes) = splitAttributes(title)

            while let last = indentStack.last, last >= indent { indentStack.removeLast() }
            let depth = indentStack.count
            indentStack.append(indent)
            items.append(TaskItem(
                title: text, state: state, depth: depth, isCollapsed: flags.contains("collapsed"),
                attributes: attributes))
        }
        return Outline(title: title, items: items, schedule: schedule, titleAttributes: titleAttributes,
                       preamble: preamble)
    }

    /// The list title a file would decode to, without decoding the rest.
    public static func title(in text: String) -> String? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let (indent, content) = splitIndent(rawLine)
            var rest = content.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            _ = takeMarker(from: &rest)
            if rest.isEmpty { continue }
            guard indent == 0, let heading = parseHeading(rest), heading.level == 1 else { return nil }
            return splitAttributes(heading.text).text
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

    static func headingLine(level: Int, title: String, attributes: String? = nil) -> String {
        let hashes = String(repeating: "#", count: level)
        let text = [title, attributes ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? hashes : "\(hashes) \(text)"
    }

    /// Splits a trailing attribute block off a heading's text:
    /// `"Setup {#setup .wide}"` → `("Setup", "{#setup .wide}")`. Only a block
    /// after some text counts, so a heading that's all braces stays as it is.
    public static func splitAttributes(_ text: String) -> (text: String, attributes: String?) {
        guard let range = text.range(of: #"\s+\{[^{}]*\}$"#, options: .regularExpression) else { return (text, nil) }
        let attributes = text[range].trimmingCharacters(in: .whitespaces)
        return (String(text[..<range.lowerBound]), attributes)
    }

    /// Whether the text is nothing but an attribute block, `{#id .class}`.
    static func isAttributeBlock(_ text: String) -> Bool {
        text.range(of: #"^\{[^{}]*\}$"#, options: .regularExpression) != nil
    }

    /// Notes (`TaskItem.notes`) as the paragraphs to show: lines joined up,
    /// split at blank lines and before numbered items and quotes, without attribute blocks (`{…}` lines, or at the
    /// end of a line) or HTML comments, which a Markdown reader doesn't see.
    public static func paragraphs(of notes: [String]) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        func finish() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }
        for note in notes {
            var line = note.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { finish(); continue }
            if let bulletless = dropBullet(line) {
                let text = dropCheckbox(bulletless)?.title ?? bulletless
                if isAttributeBlock(text) { continue }
            }
            if isAttributeBlock(line) { continue }
            if line.hasPrefix("<!--") && line.hasSuffix("-->") { continue }
            line = splitAttributes(line).text
            // Numbered items and quotes start lines of their own; other
            // lines run on, as wrapped Markdown paragraphs do.
            if line.range(of: #"^(\d+[.)]|>)\s"#, options: .regularExpression) != nil { finish() }
            current.append(line)
        }
        finish()
        return paragraphs
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
