import Foundation

public enum TaskState: String, Sendable, CaseIterable {
    case open
    /// Completed; shown struck through.
    case done
    /// Completed and tidied away; hidden unless "show decrufted" is on.
    /// Kept in the file unless the Delete decrufted tasks setting is on.
    case decrufted
}

public struct TaskItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var state: TaskState
    /// Nesting level; 0 is top level.
    public var depth: Int
    /// When true, the item's descendants (or, for a heading, its section) are hidden.
    public var isCollapsed: Bool
    /// 1–3 for a heading (`#`, `##`, `###`); nil for a task. Headings are
    /// titles, not tasks: always top level, never done, and never parents.
    public var headingLevel: Int?
    /// A trailing attribute block from the file, e.g. `{#setup .wide}`
    /// (Pandoc, kramdown and others write these), on a heading or a task.
    /// Not shown, but written back after the text so the file keeps it.
    public var attributes: String?
    /// Lines from the file after this item that aren't tasks or headings
    /// (paragraphs, notes, attribute-only lines), verbatim: shown read-only
    /// under the item and written back after it, so they travel with it.
    /// Blank lines between them are kept as empty strings.
    public var notes: [String]

    public var isHeading: Bool { headingLevel != nil }

    public init(
        id: UUID = UUID(),
        title: String,
        state: TaskState = .open,
        depth: Int = 0,
        isCollapsed: Bool = false,
        headingLevel: Int? = nil,
        attributes: String? = nil,
        notes: [String] = []
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.depth = depth
        self.isCollapsed = isCollapsed
        self.headingLevel = headingLevel
        self.attributes = attributes
        self.notes = notes
    }
}

/// A task tree stored as a flat, pre-order list of items with depths.
///
/// Invariant: the first item has depth 0 and every item's depth is at most
/// one more than the item before it. An item's subtree is the run of
/// following items with a greater depth.
///
/// Headings have depth 0, and the item after a heading has depth 0 too, so a
/// heading never has children. Instead it heads a *section*: the items up to
/// the next heading of the same or a higher level (`sectionEnd`).
public struct Outline: Equatable, Sendable {
    public private(set) var items: [TaskItem]
    /// The list's own title, stored as a `#` heading on the file's first line.
    /// Not an item; nil when the file doesn't start with one.
    public var title: String?
    /// Set when this list is a repeating checklist's template.
    public var schedule: RepeatSchedule?
    /// The title's attribute block, if the file has one (see `TaskItem.attributes`).
    public var titleAttributes: String?
    /// Lines before the first item that aren't tasks or headings (see
    /// `TaskItem.notes`).
    public var preamble: [String]

    public init(
        title: String? = nil, items: [TaskItem] = [], schedule: RepeatSchedule? = nil, titleAttributes: String? = nil,
        preamble: [String] = []
    ) {
        self.title = title
        self.titleAttributes = titleAttributes
        self.preamble = preamble
        self.items = items
        self.schedule = schedule
        var previousDepth = -1
        for i in self.items.indices {
            if let level = self.items[i].headingLevel {
                self.items[i].headingLevel = min(max(level, 1), 3)
                self.items[i].depth = 0
                self.items[i].state = .open
                previousDepth = -1
                continue
            }
            let depth = min(max(self.items[i].depth, 0), previousDepth + 1)
            self.items[i].depth = depth
            previousDepth = depth
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    public func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: - Structure queries

    /// Index one past the end of the subtree rooted at `index`.
    public func subtreeEnd(_ index: Int) -> Int {
        let depth = items[index].depth
        var end = index + 1
        while end < items.count, items[end].depth > depth { end += 1 }
        return end
    }

    public func hasChildren(_ index: Int) -> Bool {
        index + 1 < items.count && items[index + 1].depth > items[index].depth
    }

    /// For a heading: one past the last item of its section.
    public func sectionEnd(_ index: Int) -> Int {
        guard let level = items[index].headingLevel else { return subtreeEnd(index) }
        var end = index + 1
        while end < items.count {
            if let other = items[end].headingLevel, other <= level { break }
            end += 1
        }
        return end
    }

    /// Whether collapsing the item would hide anything.
    public func canCollapse(_ index: Int) -> Bool {
        items[index].isHeading ? sectionEnd(index) > index + 1 : hasChildren(index)
    }

    public func parentIndex(_ index: Int) -> Int? {
        let depth = items[index].depth
        guard depth > 0 else { return nil }
        return items[..<index].lastIndex { $0.depth == depth - 1 }
    }

    /// The nearest earlier item with the same parent, if any.
    public func previousSiblingIndex(_ index: Int) -> Int? {
        let depth = items[index].depth
        var i = index - 1
        while i >= 0 {
            if items[i].depth == depth { return i }
            if items[i].depth < depth { return nil }
            i -= 1
        }
        return nil
    }

    /// Indices of items that should be displayed: anything under a collapsed
    /// item is hidden, and decrufted items (with their subtrees) are hidden
    /// unless `showDecrufted` is set.
    public func visibleIndices(showDecrufted: Bool) -> [Int] {
        var result: [Int] = []
        var hiddenBelowDepth: Int?
        var hiddenUnderHeadingLevel: Int?
        for (i, item) in items.enumerated() {
            if let hidden = hiddenUnderHeadingLevel {
                guard let level = item.headingLevel, level <= hidden else { continue }
                hiddenUnderHeadingLevel = nil
            }
            if let hidden = hiddenBelowDepth {
                if item.depth > hidden { continue }
                hiddenBelowDepth = nil
            }
            if item.state == .decrufted && !showDecrufted {
                hiddenBelowDepth = item.depth
                continue
            }
            result.append(i)
            if item.isCollapsed {
                if let level = item.headingLevel {
                    hiddenUnderHeadingLevel = level
                } else if hasChildren(i) {
                    hiddenBelowDepth = item.depth
                }
            }
        }
        return result
    }

    // MARK: - Editing

    public mutating func setTitle(_ title: String, at index: Int) {
        items[index].title = title
    }

    /// Appends an empty top-level task and returns its index.
    @discardableResult
    public mutating func appendItem() -> Int {
        items.append(TaskItem(title: ""))
        reveal(items.count - 1)
        return items.count - 1
    }

    /// Inserts an empty task "after" `index` the way an outliner does on Return:
    /// as the first child if the item has expanded children, otherwise as the
    /// next sibling. Returns the new item's index.
    @discardableResult
    public mutating func insertItem(after index: Int) -> Int {
        let item = items[index]
        if hasChildren(index) && !item.isCollapsed {
            items.insert(TaskItem(title: "", depth: item.depth + 1), at: index + 1)
            return index + 1
        }
        let position = subtreeEnd(index)
        items.insert(TaskItem(title: "", depth: item.depth), at: position)
        reveal(position)
        return position
    }

    /// Return in a row whose selection is `selection` (UTF-16 offsets into
    /// the title; nil means the caret is at the end). Returns the row to
    /// focus and where its caret goes (nil: at the end).
    ///
    /// - An empty, childless nested task moves out a level, so Return twice
    ///   steps back out.
    /// - Otherwise the selection is deleted and the title split there: the
    ///   text after it becomes a new task after this one. At the very start,
    ///   an empty task goes in above instead, so the row keeps its children.
    @discardableResult
    public mutating func returnKey(at index: Int, selection: Range<Int>? = nil) -> (index: Int, caret: Int?) {
        let title = items[index].title
        if title.isEmpty, !hasChildren(index), let newIndex = outdent(at: index) {
            return (newIndex, nil)
        }
        let utf16 = title.utf16
        let lower = min(max(selection?.lowerBound ?? utf16.count, 0), utf16.count)
        let upper = min(max(selection?.upperBound ?? utf16.count, lower), utf16.count)
        let head = String(title[..<utf16.index(utf16.startIndex, offsetBy: lower)])
        let tail = String(title[utf16.index(utf16.startIndex, offsetBy: upper)...])

        if head.isEmpty && !tail.isEmpty {
            items[index].title = tail
            items.insert(TaskItem(title: "", depth: items[index].depth), at: index)
            return (index + 1, 0)
        }
        items[index].title = head
        let newIndex = insertItem(after: index)
        items[newIndex].title = tail
        return (newIndex, 0)
    }

    /// Makes the item (with its subtree) the last child of its previous sibling.
    /// Returns false if there is no previous sibling, or either is a heading.
    @discardableResult
    public mutating func indent(at index: Int) -> Bool {
        guard !items[index].isHeading,
              let parent = previousSiblingIndex(index),
              !items[parent].isHeading
        else { return false }
        items[parent].isCollapsed = false
        for i in index..<subtreeEnd(index) { items[i].depth += 1 }
        return true
    }

    /// Moves the item (with its subtree) out one level, placing it after its
    /// parent's subtree. Following siblings stay with the old parent.
    /// Returns the item's new index, or nil if it is already top level.
    @discardableResult
    public mutating func outdent(at index: Int) -> Int? {
        guard let parent = parentIndex(index) else { return nil }
        let parentEnd = subtreeEnd(parent)
        let end = subtreeEnd(index)
        var block = Array(items[index..<end])
        for i in block.indices { block[i].depth -= 1 }
        items.removeSubrange(index..<end)
        let destination = parentEnd - block.count
        items.insert(contentsOf: block, at: destination)
        return destination
    }

    /// The tasks a Sort on the item at `index` reorders: the level it's on,
    /// i.e. the task and its siblings (for a top-level task, those between
    /// the headings either side of it); for a heading, the tasks under it up
    /// to the next heading. Nil if that's fewer than two.
    public func sortRange(for index: Int) -> Range<Int>? {
        let range: Range<Int>
        if items[index].isHeading {
            range = (index + 1)..<nextHeading(after: index)
        } else if let parent = parentIndex(index) {
            range = (parent + 1)..<subtreeEnd(parent)
        } else {
            let start = items[..<index].lastIndex(where: \.isHeading).map { $0 + 1 } ?? 0
            range = start..<nextHeading(after: index)
        }
        guard let first = range.first else { return nil }
        let depth = items[first].depth
        return range.filter({ items[$0].depth == depth }).count > 1 ? range : nil
    }

    private func nextHeading(after index: Int) -> Int {
        items[(index + 1)...].firstIndex(where: \.isHeading) ?? items.count
    }

    /// Sorts the tasks `sortRange(for:)` picks by title, A–Z the way Finder
    /// does (ignoring case, numbers by value, so "2" comes before "10").
    /// Each task keeps its subtasks; untitled tasks go last. Returns whether
    /// the order changed.
    @discardableResult
    public mutating func sortTasks(for index: Int) -> Bool {
        guard let range = sortRange(for: index) else { return false }
        let depth = items[range.lowerBound].depth
        var blocks: [ArraySlice<TaskItem>] = []
        var start = range.lowerBound
        for i in range.dropFirst() where items[i].depth == depth {
            blocks.append(items[start..<i])
            start = i
        }
        blocks.append(items[start..<range.upperBound])
        // Stable, so equal titles keep their order.
        let sorted = blocks.enumerated().sorted { a, b in
            let x = a.element.first!.title, y = b.element.first!.title
            if x.isEmpty != y.isEmpty { return y.isEmpty }
            switch x.localizedStandardCompare(y) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
        let reordered = Array(sorted.joined())
        guard reordered.map(\.id) != items[range].map(\.id) else { return false }
        items.replaceSubrange(range, with: reordered)
        return true
    }

    /// Swaps the item's subtree with its previous sibling's. Returns the new index.
    /// A top-level task can swap with a heading, moving it into the section
    /// above. Headings themselves don't move this way.
    @discardableResult
    public mutating func moveUp(at index: Int) -> Int? {
        guard !items[index].isHeading, let sibling = previousSiblingIndex(index) else { return nil }
        let end = subtreeEnd(index)
        let moved = items[index..<end] + items[sibling..<index]
        items.replaceSubrange(sibling..<end, with: moved)
        reveal(sibling)
        return sibling
    }

    /// Swaps the item's subtree with its next sibling's. Returns the new index.
    @discardableResult
    public mutating func moveDown(at index: Int) -> Int? {
        guard !items[index].isHeading else { return nil }
        let end = subtreeEnd(index)
        guard end < items.count, items[end].depth == items[index].depth else { return nil }
        let nextEnd = subtreeEnd(end)
        let moved = items[end..<nextEnd] + items[index..<end]
        items.replaceSubrange(index..<nextEnd, with: moved)
        let newIndex = index + (nextEnd - end)
        reveal(newIndex)
        return newIndex
    }

    /// The depths the subtree at `index` could take if moved to just before
    /// `destination` (an index into `items` as they are now; `items.count`
    /// means the end). Nil for a heading, or a destination inside the subtree.
    /// The range runs from the depth of the item that would follow (so it
    /// isn't adopted as a child) to one deeper than the item that would precede.
    public func moveDepths(at index: Int, to destination: Int) -> ClosedRange<Int>? {
        let end = subtreeEnd(index)
        guard !items[index].isHeading, destination <= index || destination >= end,
              destination <= items.count
        else { return nil }
        let previous = destination == end ? index - 1 : destination - 1
        let next = destination == index ? end : destination
        let maxDepth = previous < 0 || items[previous].isHeading ? 0 : items[previous].depth + 1
        let minDepth = next < items.count && !items[next].isHeading ? items[next].depth : 0
        return minDepth...maxDepth
    }

    /// The gap a dragged row is dropped into, in terms of the visible rows
    /// either side of it (indices into `items`, neither inside the dragged
    /// subtree): where the subtree would go and the depths it may take.
    /// Beyond `moveDepths`, the depth is capped by the visible row above, so a
    /// drop below a collapsed task can make it that task's last child but
    /// can't burrow deeper into what's hidden.
    public func dropTarget(
        moving index: Int, afterVisible previous: Int?, beforeVisible next: Int?
    ) -> (destination: Int, depths: ClosedRange<Int>)? {
        let destination = next ?? items.count
        guard let depths = moveDepths(at: index, to: destination) else { return nil }
        let visibleMax = previous.map { items[$0].isHeading ? 0 : items[$0].depth + 1 } ?? 0
        let capped = depths.lowerBound...max(depths.lowerBound, min(depths.upperBound, visibleMax))
        return (destination, capped)
    }

    /// Moves the item and its subtree to just before `destination` (see
    /// `moveDepths`), at `depth`, keeping the subtree's shape. Collapsed
    /// parents and headings it lands under are expanded so it stays visible.
    /// Returns the item's new index, or nil if the move isn't allowed.
    @discardableResult
    public mutating func move(at index: Int, to destination: Int, depth: Int) -> Int? {
        guard let depths = moveDepths(at: index, to: destination), depths.contains(depth) else { return nil }
        let end = subtreeEnd(index)
        var block = Array(items[index..<end])
        let shift = depth - block[0].depth
        for i in block.indices { block[i].depth += shift }
        items.removeSubrange(index..<end)
        let newIndex = destination > index ? destination - block.count : destination
        items.insert(contentsOf: block, at: newIndex)
        var ancestor = parentIndex(newIndex)
        while let a = ancestor {
            items[a].isCollapsed = false
            ancestor = parentIndex(a)
        }
        reveal(newIndex)
        return newIndex
    }

    /// Turns the item into a heading of `level`. A nested task is first
    /// outdented to the top level, and its children move up a level since
    /// headings can't have children. Returns the item's new index.
    @discardableResult
    public mutating func makeHeading(level: Int, at index: Int) -> Int {
        var index = index
        if !items[index].isHeading {
            while items[index].depth > 0, let outdented = outdent(at: index) { index = outdented }
            for i in (index + 1)..<subtreeEnd(index) { items[i].depth -= 1 }
            items[index].state = .open
            items[index].isCollapsed = false
        }
        items[index].headingLevel = min(max(level, 1), 3)
        return index
    }

    /// Turns a heading back into a top-level task.
    public mutating func makeTask(at index: Int) {
        guard items[index].isHeading else { return }
        items[index].headingLevel = nil
        items[index].isCollapsed = false
    }

    /// Expands any collapsed headings whose section contains `index`, so an
    /// item that was just created or moved there doesn't vanish.
    private mutating func reveal(_ index: Int) {
        var nearestLevel = Int.max
        var i = index - 1
        while i >= 0, nearestLevel > 1 {
            if let level = items[i].headingLevel, level < nearestLevel {
                items[i].isCollapsed = false
                nearestLevel = level
            }
            i -= 1
        }
    }

    /// Removes the item and its subtree.
    public mutating func removeSubtree(at index: Int) {
        items.removeSubrange(index..<subtreeEnd(index))
    }

    /// Delete at the start of a task: appends its title to `previous` (the
    /// row shown above it) and removes it. Its subtasks become the last
    /// subtasks of `previous`, or stay where they were if they're already
    /// inside it; under a heading they're top-level. Returns the offset
    /// (UTF-16) where the two titles meet, for the caret.
    @discardableResult
    public mutating func join(_ index: Int, into previous: Int) -> Int {
        precondition(previous < index && !items[index].isHeading)
        let item = items[index]
        let caret = items[previous].title.utf16.count
        let end = subtreeEnd(index)
        var children = Array(items[(index + 1)..<end])
        let isInside = items[previous].isHeading || index < subtreeEnd(previous)
        items.removeSubrange(index..<end)
        items[previous].title += item.title
        if !item.notes.isEmpty {
            if !items[previous].notes.isEmpty { items[previous].notes.append("") }
            items[previous].notes += item.notes
        }
        guard !children.isEmpty else { return caret }

        let base = items[previous].isHeading ? 0 : items[previous].depth + 1
        for k in children.indices { children[k].depth += base - (item.depth + 1) }
        let at = isInside ? index : subtreeEnd(previous)
        items.insert(contentsOf: children, at: at)
        if !items[previous].isHeading { items[previous].isCollapsed = false }
        return caret
    }

    /// The item at `index` with its subtree, moved up to the top level.
    public func subtreeItems(at index: Int) -> [TaskItem] {
        let base = items[index].depth
        return items[index..<subtreeEnd(index)].map { item in
            var item = item
            item.depth -= base
            return item
        }
    }

    /// Adds a top-level item and its subtree (as from `subtreeItems`) at the
    /// end. A blank last task, the row left for typing into, stays last.
    public mutating func appendSubtree(_ subtree: [TaskItem]) {
        guard let base = subtree.first?.depth else { return }
        let added = subtree.map { item in
            var item = item
            item.id = UUID()
            item.depth -= base
            return item
        }
        var end = items.count
        if let last = items.last, !last.isHeading, last.depth == 0, last.title.isEmpty { end -= 1 }
        items.insert(contentsOf: added, at: end)
    }

    /// Open becomes done; done or decrufted becomes open.
    public mutating func toggleDone(at index: Int) {
        guard !items[index].isHeading else { return }
        items[index].state = items[index].state == .open ? .done : .open
    }

    public mutating func setCollapsed(_ collapsed: Bool, at index: Int) {
        items[index].isCollapsed = collapsed
    }

    /// Gives items the ids of their counterparts in `old`, so a reloaded
    /// outline keeps row identity (and the row being edited keeps focus).
    /// Items are matched as a longest common subsequence on depth, kind and
    /// title; between matches, runs of the same length pair up in order,
    /// which covers rows whose title was edited.
    public mutating func adoptIdentities(from old: Outline) {
        func key(_ item: TaskItem) -> String { "\(item.depth)|\(item.headingLevel ?? 0)|\(item.title)" }
        var previousOld = 0, previousNew = 0
        for (o, n) in Diff.matches(old.items.map(key), items.map(key)) + [(old.items.count, items.count)] {
            if o - previousOld == n - previousNew {
                for k in 0..<(n - previousNew) { items[previousNew + k].id = old.items[previousOld + k].id }
            }
            if n < items.count { items[n].id = old.items[o].id }
            previousOld = o + 1
            previousNew = n + 1
        }
    }

    /// Moves every done task to decrufted. Returns how many changed.
    @discardableResult
    public mutating func decruftDone() -> Int {
        var count = 0
        for i in items.indices where items[i].state == .done {
            items[i].state = .decrufted
            count += 1
        }
        return count
    }

    /// Deletes every done and decrufted task, for decrufting by deleting.
    /// Open tasks under a deleted one are kept, moved up to its place.
    /// Returns how many were deleted.
    @discardableResult
    public mutating func deleteDone() -> Int {
        var kept: [TaskItem] = []
        // Depths of the deleted tasks enclosing the current item.
        var deleted: [Int] = []
        for var item in items {
            while let last = deleted.last, last >= item.depth { deleted.removeLast() }
            if !item.isHeading && item.state != .open {
                deleted.append(item.depth)
                continue
            }
            item.depth -= deleted.count
            kept.append(item)
        }
        let count = items.count - kept.count
        items = kept
        return count
    }

    // MARK: - Blocks of rows

    /// The items a selection of rows from `first` to `last` covers: those
    /// rows plus everything hidden under them (subtasks, and the section of
    /// a collapsed heading).
    public func blockRange(from first: Int, to last: Int) -> Range<Int> {
        var end = last + 1
        for i in first...last {
            let itemEnd = items[i].isHeading
                ? (items[i].isCollapsed ? sectionEnd(i) : i + 1)
                : subtreeEnd(i)
            end = max(end, itemEnd)
        }
        return first..<end
    }

    /// The items in `range`, moved out so the shallowest is top level.
    public func blockItems(_ range: Range<Int>) -> [TaskItem] {
        guard let base = items[range].map(\.depth).min() else { return [] }
        return items[range].map { item in
            var item = item
            item.depth -= base
            return item
        }
    }

    /// Removes the items in `range`. Anything after it that would now be
    /// nested too deeply moves out to fit.
    public mutating func removeBlock(_ range: Range<Int>) {
        items.removeSubrange(range)
        self = Outline(title: title, items: items, schedule: schedule)
    }

    /// Inserts `block` (as from `blockItems`, with fresh ids) where a new
    /// task after `index` would go, at that task's depth. If the row at
    /// `index` is an empty task with nothing under it, the block replaces
    /// it. Returns the range the block now occupies.
    @discardableResult
    public mutating func insertBlock(_ block: [TaskItem], at index: Int) -> Range<Int> {
        guard !block.isEmpty else { return index..<index }
        let row = items[index]
        if !row.isHeading, row.title.isEmpty, !hasChildren(index) {
            return replaceBlock(index..<(index + 1), with: block)
        }
        let position: Int
        let depth: Int
        if row.isHeading {
            (position, depth) = (row.isCollapsed ? sectionEnd(index) : index + 1, 0)
        } else if hasChildren(index) && !row.isCollapsed {
            (position, depth) = (index + 1, row.depth + 1)
        } else {
            (position, depth) = (subtreeEnd(index), row.depth)
        }
        return place(block, in: position..<position, depth: depth)
    }

    /// Replaces the items in `range` with `block` (with fresh ids), at the
    /// depth of the first item replaced. Returns the range the block occupies.
    @discardableResult
    public mutating func replaceBlock(_ range: Range<Int>, with block: [TaskItem]) -> Range<Int> {
        place(block, in: range, depth: items[range.lowerBound].depth)
    }

    private mutating func place(_ block: [TaskItem], in range: Range<Int>, depth: Int) -> Range<Int> {
        let base = block.map(\.depth).min() ?? 0
        let added = block.map { item in
            var item = item
            item.id = UUID()
            item.depth += depth - base
            return item
        }
        items.replaceSubrange(range, with: added)
        self = Outline(title: title, items: items, schedule: schedule)
        if !added.isEmpty { reveal(range.lowerBound) }
        return range.lowerBound..<(range.lowerBound + added.count)
    }

    /// Marks the tasks at `indices` done, or open again.
    public mutating func setDone(_ done: Bool, at indices: [Int]) {
        for i in indices where !items[i].isHeading {
            if done {
                if items[i].state == .open { items[i].state = .done }
            } else {
                items[i].state = .open
            }
        }
    }
}
