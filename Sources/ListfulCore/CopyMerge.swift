import Foundation

/// Merging two versions of a repeating checklist's copy, task by task.
///
/// Two devices that are out of touch (one on a train, say) can each make
/// the same day's copy and tick things off in it. When they sync, iCloud
/// keeps one version and hides or renames the other. A merge by line clashes
/// all over the place, since the two were written separately, so copies are
/// merged by task instead: tasks are matched by title (the first “Prayers”
/// with the first, the second with the second), wherever they are.
///
/// `base`, the copy as this device made it, and `template` let the merge
/// tell a change from a difference. Every device's copy starts with the
/// template's tasks; only the carried-over ones can differ, if a device
/// hadn't yet synced the previous copy when it made this one.
/// - A task ticked or unticked on one side takes that side's state. With no
///   base, or both sides changed, a done task wins.
/// - A task moved to another parent or heading on one side moves.
/// - A task that's gone from one side was decrufted or deleted there, so it
///   goes (leaving any open subtasks in its place) if it's done on the
///   other, or is the template's and untouched there. A carried-over open
///   task that's gone from `b` stays, since `b` may never have had it; one
///   gone from `a` goes only when `a` is this device's version (`aIsMine`).
/// - A task added on either side is kept, after the task it follows there.
extension RepeatingChecklists {
    public static func mergeVersions(
        _ a: Outline, _ b: Outline, base: Outline? = nil, template: Outline? = nil, aIsMine: Bool = false
    ) -> Outline {
        let treeA = MergeTree(a), treeB = MergeTree(b)
        let baseTree = base.map(MergeTree.init), templateTree = template.map(MergeTree.init)
        /// Whether `node`, which the other version hasn't got, was removed there.
        func removedElsewhere(_ node: MergeNode) -> Bool {
            guard let item = node.item else { return false }
            let baseNode = baseTree?.nodes[node.key]
            let inTemplate = templateTree?.nodes[node.key] != nil
            if item.state != .open { return baseNode != nil || inTemplate }
            return inTemplate && item.state == baseNode?.item?.state ?? .open
        }
        // Where each of a's tasks was before anything moved.
        let originalParent = treeA.nodes.mapValues { $0.parent?.key }
        var result = treeA.nodes

        // States, and done tasks decrufted on the other side.
        for node in treeA.order where node.item?.isHeading == false {
            if let other = treeB.nodes[node.key] {
                let base = baseTree?.nodes[node.key]?.item?.state
                node.item!.state = mergedState(base: base, node.item!.state, other.item!.state)
            } else if removedElsewhere(node) {
                node.removeLiftingChildren()
                result[node.key] = nil
            }
        }

        // Tasks and headings only b has.
        for other in treeB.order where treeA.nodes[other.key] == nil {
            guard let item = other.item, !other.isBlank else { continue }
            if aIsMine && baseTree?.nodes[other.key] != nil || removedElsewhere(other) { continue }
            let parent = item.isHeading ? treeA.root : nearest(other.parent, in: result) ?? treeA.root.children[0]
            let node = MergeNode(key: other.key, item: item)
            parent.insert(node, at: position(after: other, among: parent, in: result))
            result[other.key] = node
        }

        // Tasks moved on b's side only.
        if let baseTree {
            for other in treeB.order where other.item?.isHeading == false {
                guard let node = result[other.key], treeA.nodes[other.key] != nil,
                      let baseParent = baseTree.nodes[other.key]?.parent?.key,
                      let otherParent = other.parent?.key,
                      originalParent[other.key] == baseParent, otherParent != baseParent,
                      let target = result[otherParent], !node.contains(target)
                else { continue }
                node.parent?.remove(node)
                target.insert(node, at: position(after: other, among: target, in: result))
            }
        }

        return Outline(
            title: a.title, items: treeA.root.flattened(), schedule: a.schedule,
            titleAttributes: a.titleAttributes, preamble: a.preamble)
    }

    private static func mergedState(base: TaskState?, _ a: TaskState, _ b: TaskState) -> TaskState {
        if a == b { return a }
        if let base {
            if a == base { return b }
            if b == base { return a }
        }
        return a != .open ? a : b
    }

    /// The node in `result` for `node`, or for its nearest ancestor that's there.
    private static func nearest(_ node: MergeNode?, in result: [String: MergeNode]) -> MergeNode? {
        var node = node
        while let current = node {
            if let found = result[current.key] { return found }
            node = current.parent
        }
        return nil
    }

    /// Where `node` (from the other version) goes among `parent`'s children:
    /// after the nearest of its earlier siblings there, or first.
    private static func position(after node: MergeNode, among parent: MergeNode, in result: [String: MergeNode]) -> Int {
        guard let siblings = node.parent?.children, let index = siblings.firstIndex(where: { $0 === node }) else { return 0 }
        for sibling in siblings[..<index].reversed() {
            if let placed = result[sibling.key], placed.parent === parent,
               let at = parent.children.firstIndex(where: { $0 === placed }) {
                return at + 1
            }
        }
        return 0
    }
}

/// An outline as a tree, for merging: the root's children are its sections
/// (the part before the first heading, then each heading), and a section's
/// children are its top-level tasks.
private final class MergeNode {
    let key: String
    var item: TaskItem?
    var children: [MergeNode] = []
    weak var parent: MergeNode?

    init(key: String, item: TaskItem?) {
        self.key = key
        self.item = item
    }

    var isBlank: Bool {
        item?.isHeading == false && item!.title.trimmingCharacters(in: .whitespaces).isEmpty && children.isEmpty
    }

    func insert(_ child: MergeNode, at index: Int) {
        child.parent = self
        children.insert(child, at: min(index, children.count))
    }

    func remove(_ child: MergeNode) {
        children.removeAll { $0 === child }
        child.parent = nil
    }

    /// Takes this node out, putting its children in its place.
    func removeLiftingChildren() {
        guard let parent, let index = parent.children.firstIndex(where: { $0 === self }) else { return }
        parent.children.remove(at: index)
        for child in children { child.parent = parent }
        parent.children.insert(contentsOf: children, at: index)
        children = []
        self.parent = nil
    }

    func contains(_ node: MergeNode) -> Bool {
        var current: MergeNode? = node
        while let c = current {
            if c === self { return true }
            current = c.parent
        }
        return false
    }

    /// Items in file order, with depths from the tree.
    func flattened() -> [TaskItem] {
        var items: [TaskItem] = []
        func add(_ node: MergeNode, depth: Int) {
            guard var item = node.item else { return }
            item.depth = depth
            items.append(item)
            for child in node.children { add(child, depth: depth + 1) }
        }
        for section in children {
            if let heading = section.item { items.append(heading) }
            for node in section.children { add(node, depth: 0) }
        }
        return items
    }
}

private struct MergeTree {
    let root = MergeNode(key: "", item: nil)
    /// Every section and task by key.
    private(set) var nodes: [String: MergeNode] = [:]
    /// Sections and tasks in file order (parents before children).
    private(set) var order: [MergeNode] = []

    init(_ outline: Outline) {
        var counts: [String: Int] = [:]
        func key(_ base: String) -> String {
            let n = counts[base, default: 0]
            counts[base] = n + 1
            return "\(base)\u{1}\(n)"
        }
        var section = MergeNode(key: "section", item: nil)
        root.insert(section, at: 0)
        nodes[section.key] = section
        order.append(section)
        var stack: [MergeNode] = []
        for item in outline.items {
            let title = item.title.trimmingCharacters(in: .whitespaces)
            if let level = item.headingLevel {
                section = MergeNode(key: key("h\(level)\u{1}\(title)"), item: item)
                root.insert(section, at: root.children.count)
                nodes[section.key] = section
                order.append(section)
                stack = []
                continue
            }
            let node = MergeNode(key: key("t\u{1}\(title)"), item: item)
            while stack.count > item.depth { stack.removeLast() }
            (stack.last ?? section).insert(node, at: Int.max)
            stack.append(node)
            nodes[node.key] = node
            order.append(node)
        }
    }
}
