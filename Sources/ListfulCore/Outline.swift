import Foundation

public enum TaskState: String, Sendable, CaseIterable {
    case open
    /// Completed; shown struck through.
    case done
    /// Completed and tidied away; hidden unless "show decrufted" is on. Never deleted.
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

    public var isHeading: Bool { headingLevel != nil }

    public init(
        id: UUID = UUID(),
        title: String,
        state: TaskState = .open,
        depth: Int = 0,
        isCollapsed: Bool = false,
        headingLevel: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.depth = depth
        self.isCollapsed = isCollapsed
        self.headingLevel = headingLevel
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

    public init(title: String? = nil, items: [TaskItem] = []) {
        self.title = title
        self.items = items
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

    /// Open becomes done; done or decrufted becomes open.
    public mutating func toggleDone(at index: Int) {
        guard !items[index].isHeading else { return }
        items[index].state = items[index].state == .open ? .done : .open
    }

    public mutating func setCollapsed(_ collapsed: Bool, at index: Int) {
        items[index].isCollapsed = collapsed
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
}
