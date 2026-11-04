import Foundation

/// Repeating checklists: templates (lists with a `RepeatSchedule`, kept in a
/// templates folder) that are copied into the lists folder once per period,
/// as "<template> <period key>.md". A copy's existence is what records that a
/// period has been done, so making copies is idempotent, and two Macs sharing
/// the folder through iCloud find each other's copies instead of repeating them.
public enum RepeatingChecklists {
    /// The name a template's copy for a period gets, without the extension.
    public static func copyName(template: String, key: String) -> String {
        "\(template) \(key)"
    }

    /// The lists among `lists` that are copies of the template called
    /// `template`, newest first. A copy is "<template> <key>" for a period key
    /// of any frequency, so copies made before a schedule change still count.
    public static func copies(ofTemplateNamed template: String, in lists: [URL]) -> [URL] {
        let prefix = template + " "
        return lists
            .compactMap { url -> (key: String, url: URL)? in
                let name = TaskLibrary.displayName(of: url)
                guard name.hasPrefix(prefix) else { return nil }
                let key = String(name.dropFirst(prefix.count))
                let isKey = RepeatSchedule.Frequency.allCases.contains { RepeatSchedule(frequency: $0).isPeriodKey(key) }
                return isKey ? (key, url) : nil
            }
            .sorted { $0.key > $1.key }
            .map(\.url)
    }

    /// Whether a list has any task left to do (a blank row doesn't count).
    public static func hasOpenTasks(_ outline: Outline) -> Bool {
        outline.items.contains { item in
            !item.isHeading && item.state == .open && !item.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// A fresh copy of `template`: every task open again, titled "<title> — <label>",
    /// without the schedule. If `previous` (the template's last copy) is
    /// given, its unfinished tasks are moved to the top of the copy, and the
    /// previous copy without them is returned too (nil if nothing moved).
    ///
    /// What moves: each open task with its whole subtree, done subtasks
    /// included. Under a done task, its open subtasks move on their own. A
    /// moved task that the copy already has (same title, at the same place)
    /// isn't duplicated; its subtasks are merged in instead. Tasks under a
    /// heading go into the copy's heading of the same name, or under a new
    /// one at the end if the template doesn't have it.
    public static func makeCopy(
        of template: Outline, name: String, label: String, carryingOverFrom previous: Outline?
    ) -> (copy: Outline, previous: Outline?) {
        var copySections = sections(of: template.items.map { item in
            var item = item
            item.id = UUID()
            if !item.isHeading { item.state = .open }
            return item
        }).map { section in
            var section = section
            section.nodes = dropBlank(section.nodes)
            return section
        }
        var updatedPrevious: Outline?

        if let previous {
            var kept: [Section] = []
            var moved = false
            for section in sections(of: previous.items) {
                var remaining: [Node] = []
                var carried: [Node] = []
                for node in section.nodes {
                    let (keep, carry) = extractUnfinished(node)
                    if let keep { remaining.append(keep) }
                    carried += carry
                }
                // A blank row left at the end of the list stays where it is.
                let blank = carried.filter(isBlank)
                remaining += blank
                carried = carried.filter { !isBlank($0) }
                kept.append(Section(heading: section.heading, nodes: remaining))
                guard !carried.isEmpty else { continue }
                moved = true
                let target = copySections.firstIndex { sameHeading($0.heading, section.heading) }
                if let target {
                    merge(carried, into: &copySections[target].nodes)
                } else if section.heading == nil {
                    copySections.insert(Section(heading: nil, nodes: carried), at: 0)
                } else {
                    copySections.append(Section(heading: section.heading, nodes: carried))
                }
            }
            if moved {
                updatedPrevious = Outline(title: previous.title, items: flatten(kept), schedule: previous.schedule)
            }
        }

        let title = "\(template.title ?? name) — \(label)"
        return (Outline(title: title, items: flatten(copySections)), updatedPrevious)
    }

    /// The outcome of `makeDueCopies` for one template.
    public struct Result: Sendable {
        public let template: URL
        /// The copy made, if one was due.
        public let copy: URL?
        /// The copy that unfinished tasks were moved out of, if any.
        public let previous: URL?
        public let error: String?
    }

    /// Makes each template's copy for the period containing `date`, if it
    /// doesn't exist yet. Templates with no tasks written in them are skipped,
    /// so a new template isn't copied before it's been filled in.
    public static func makeDueCopies(
        templates: TaskLibrary, lists: TaskLibrary,
        date: Date, calendar: Calendar, locale: Locale
    ) -> [Result] {
        guard let templateURLs = try? templates.lists() else { return [] }
        let existing = Set(((try? lists.lists()) ?? []).map(TaskLibrary.displayName(of:)))
        var results: [Result] = []
        for url in templateURLs {
            let name = TaskLibrary.displayName(of: url)
            do {
                let template = try MarkdownFileStore(fileURL: url).load()
                guard let schedule = template.schedule,
                      template.items.contains(where: { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty })
                else { continue }

                let occurrence = schedule.occurrence(onOrBefore: date, calendar: calendar)
                let key = schedule.periodKey(for: occurrence, calendar: calendar)
                let copyName = copyName(template: name, key: key)
                guard !existing.contains(copyName) else { continue }

                var previousURL: URL?
                var previous: Outline?
                if schedule.carriesOver {
                    let prefix = name + " "
                    let earlier = existing
                        .filter { $0.hasPrefix(prefix) }
                        .map { String($0.dropFirst(prefix.count)) }
                        .filter { schedule.isPeriodKey($0) && $0 < key }
                    if let last = earlier.max() {
                        previousURL = lists.url(forName: self.copyName(template: name, key: last))
                        previous = try MarkdownFileStore(fileURL: previousURL!).load()
                    }
                }

                let label = schedule.periodLabel(for: occurrence, calendar: calendar, locale: locale)
                let made = makeCopy(of: template, name: name, label: label, carryingOverFrom: previous)
                let copyURL = lists.url(forName: copyName)
                // Write the copy first, so a failure can't lose moved tasks.
                try MarkdownFileStore(fileURL: copyURL).save(made.copy)
                if let updated = made.previous, let previousURL {
                    try MarkdownFileStore(fileURL: previousURL).save(updated)
                }
                results.append(Result(template: url, copy: copyURL, previous: made.previous == nil ? nil : previousURL, error: nil))
            } catch {
                results.append(Result(
                    template: url, copy: nil, previous: nil,
                    error: "Couldn't make today's copy of “\(name)”: \(error.localizedDescription)"))
            }
        }
        return results
    }

    // MARK: - Trees

    /// An item with its subtree, for restructuring outlines.
    struct Node {
        var item: TaskItem
        var children: [Node]
    }

    /// A heading (nil for the part before the first heading) and the tasks under it.
    struct Section {
        var heading: TaskItem?
        var nodes: [Node]
    }

    static func sections(of items: [TaskItem]) -> [Section] {
        var sections: [Section] = []
        var start = 0
        var heading: TaskItem?
        func close(_ end: Int) {
            if heading != nil || end > start {
                sections.append(Section(heading: heading, nodes: forest(items[start..<end])))
            }
        }
        for (i, item) in items.enumerated() where item.isHeading {
            close(i)
            heading = item
            start = i + 1
        }
        close(items.count)
        return sections
    }

    private static func forest(_ items: ArraySlice<TaskItem>) -> [Node] {
        var nodes: [Node] = []
        var i = items.startIndex
        while i < items.endIndex {
            var end = i + 1
            while end < items.endIndex, items[end].depth > items[i].depth { end += 1 }
            nodes.append(Node(item: items[i], children: forest(items[(i + 1)..<end])))
            i = end
        }
        return nodes
    }

    static func flatten(_ sections: [Section]) -> [TaskItem] {
        var items: [TaskItem] = []
        func add(_ node: Node, depth: Int) {
            var item = node.item
            item.depth = depth
            items.append(item)
            for child in node.children { add(child, depth: depth + 1) }
        }
        for section in sections {
            if let heading = section.heading { items.append(heading) }
            for node in section.nodes { add(node, depth: 0) }
        }
        return items
    }

    /// Splits `node` into what stays behind and what moves on: an open task
    /// moves whole; a done one stays, minus its open subtasks, which move.
    private static func extractUnfinished(_ node: Node) -> (keep: Node?, carry: [Node]) {
        if node.item.state == .open { return (nil, [node]) }
        var keep = node
        keep.children = []
        var carry: [Node] = []
        for child in node.children {
            let (k, c) = extractUnfinished(child)
            if let k { keep.children.append(k) }
            carry += c
        }
        return (keep, carry)
    }

    /// Leaves out tasks with no text and no subtasks, such as the empty row
    /// left at the end of a list after typing it.
    private static func dropBlank(_ nodes: [Node]) -> [Node] {
        nodes.compactMap { node in
            var node = node
            node.children = dropBlank(node.children)
            return isBlank(node) ? nil : node
        }
    }

    private static func isBlank(_ node: Node) -> Bool {
        !node.item.isHeading && node.children.isEmpty && node.item.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Adds `carried` before `nodes`, except that a task `nodes` already has
    /// (by title) gets the carried one's subtasks merged into it instead.
    private static func merge(_ carried: [Node], into nodes: inout [Node]) {
        var fresh: [Node] = []
        for node in carried {
            if let i = nodes.firstIndex(where: { sameTitle($0.item, node.item) }) {
                merge(node.children, into: &nodes[i].children)
            } else {
                fresh.append(node)
            }
        }
        nodes.insert(contentsOf: fresh, at: 0)
    }

    private static func sameTitle(_ a: TaskItem, _ b: TaskItem) -> Bool {
        a.title.trimmingCharacters(in: .whitespaces) == b.title.trimmingCharacters(in: .whitespaces)
    }

    private static func sameHeading(_ a: TaskItem?, _ b: TaskItem?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.headingLevel == b.headingLevel && sameTitle(a, b)
    }
}
