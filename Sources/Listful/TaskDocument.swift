import AppKit
import Observation
import ListfulCore

/// One open task list: owns the outline, persists it to a `TaskStore`, and
/// exposes id-based editing actions for the views.
@MainActor @Observable
final class TaskDocument {
    private(set) var outline = Outline()
    let fileURL: URL
    let options: ViewOptions
    /// The row the user is working on; menu commands act on it.
    private(set) var focusedID: UUID?
    /// A one-shot request for a row's text field to take keyboard focus.
    /// Cleared once that field has focus, so it can't steal focus back later.
    private(set) var focusRequestID: UUID?
    /// Where the requested field puts its caret (UTF-16 offset); nil is the end.
    private(set) var focusRequestCaret: Int?
    /// Whether to show the title field: only when the file has a `#` title.
    /// Stays on if the title is cleared, so the field doesn't vanish while
    /// being edited; it's re-evaluated on load.
    private(set) var showsListTitle = false
    var errorMessage: String?

    @ObservationIgnored private let store: MarkdownFileStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The file's text as last read or written here. If the file no longer
    /// matches it, someone else (another app, or another Mac via iCloud)
    /// has changed it.
    @ObservationIgnored private var syncedText: String?
    @ObservationIgnored private var watcher: FileWatcher?

    init(fileURL: URL, options: ViewOptions) {
        self.fileURL = fileURL
        self.options = options
        store = MarkdownFileStore(fileURL: fileURL)
        load()
        watcher = FileWatcher(url: fileURL) { [weak self] in self?.checkDisk() }
    }

    var fileName: String { TaskLibrary.displayName(of: fileURL) }

    /// What to call the list: its `#` title if it has one, else the file name.
    var displayTitle: String {
        if let title = outline.title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return fileName
    }

    /// Sets the list's title; an empty title removes the `#` line from the file.
    func setListTitle(_ title: String) {
        let newTitle: String? = title.isEmpty ? nil : title
        guard newTitle != outline.title else { return }
        if newTitle != nil { showsListTitle = true }
        mutate { $0.title = newTitle }
    }

    // MARK: - Repeating checklists

    /// When true, the sheet for editing this template's schedule is shown,
    /// editing `scheduleDraft`.
    var isEditingSchedule = false
    var scheduleDraft = RepeatSchedule()

    func editSchedule() {
        guard let schedule = outline.schedule else { return }
        scheduleDraft = schedule
        isEditingSchedule = true
    }

    func commitSchedule() {
        isEditingSchedule = false
        guard scheduleDraft != outline.schedule else { return }
        mutate { $0.schedule = scheduleDraft }
    }

    // MARK: - Rows

    var visibleItems: [TaskItem] {
        outline.visibleIndices(showDecrufted: options.showDecrufted).map { outline.items[$0] }
    }

    func canCollapse(_ id: UUID) -> Bool {
        guard let i = outline.index(of: id) else { return false }
        return outline.canCollapse(i)
    }

    // MARK: - Editing

    func setTitle(_ title: String, for id: UUID) {
        guard let i = outline.index(of: id) else { return }
        let old = outline.items[i]
        guard old.title != title else { return }

        // Typing "# ", "## " or "### " at the start of a task makes it a heading.
        if !old.isHeading, let heading = MarkdownCodec.parseHeading(title) {
            let prefix = String(repeating: "#", count: heading.level) + " "
            if title.hasPrefix(prefix) && !old.title.hasPrefix(prefix) {
                mutate {
                    let index = $0.makeHeading(level: heading.level, at: i)
                    $0.setTitle(heading.text, at: index)
                }
                requestFocus(id)
                return
            }
        }
        mutate { $0.setTitle(title, at: i) }
    }

    func makeHeading(_ level: Int, for id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.makeHeading(level: level, at: i) }
        requestFocus(id)
    }

    func makeTask(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.makeTask(at: i) }
        requestFocus(id)
    }

    /// Return in a row: splits it at the selection into a new task, or
    /// moves an empty nested one out a level.
    func returnKey(_ id: UUID, selection: Range<Int>) {
        guard let i = outline.index(of: id) else { return }
        var target: (index: Int, caret: Int?) = (0, nil)
        mutate { target = $0.returnKey(at: i, selection: selection) }
        requestFocus(outline.items[target.index].id, caret: target.caret)
    }

    func appendTask() {
        var newIndex = 0
        mutate { newIndex = $0.appendItem() }
        requestFocus(outline.items[newIndex].id)
    }

    // Structural moves can make SwiftUI re-host the row's text field, which
    // drops keyboard focus, so each one re-requests focus for the moved row.

    func indent(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.indent(at: i) }
        requestFocus(id)
    }

    func outdent(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.outdent(at: i) }
        requestFocus(id)
    }

    func moveUp(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.moveUp(at: i) }
        requestFocus(id)
    }

    func moveDown(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.moveDown(at: i) }
        requestFocus(id)
    }

    func toggleDone(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.toggleDone(at: i) }
    }

    // MARK: - Dragging rows

    /// A row being dragged by its bullet, with where it would land.
    struct RowDrag: Equatable {
        let id: UUID
        /// The dragged row and its subtree, dimmed while they're dragged.
        let movingIDs: Set<UUID>
        var destination: Int
        var depth: Int
        /// The top of the gap it would drop into, in the outline's coordinates.
        var gapY: CGFloat
        /// Another list in the sidebar it would move to, if it's over one.
        var targetList: URL?
    }

    private(set) var drag: RowDrag?
    /// Each visible row's frame in the outline's coordinates, reported by the
    /// rows. Not observed: it changes on every layout and only drags read it.
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    /// Where the outline's coordinate space is, in window coordinates.
    @ObservationIgnored var outlineOrigin: CGPoint = .zero
    /// The sidebar's lists and their frames in window coordinates, which a
    /// row can be dragged onto to move it there.
    @ObservationIgnored var sidebarTargets: () -> [URL: CGRect] = { [:] }

    /// Follows a drag of `id`'s bullet (`location` in window coordinates).
    /// Over another list in the sidebar, the row would move there. Otherwise
    /// the gap is the one nearest the pointer, among the rows outside the
    /// dragged subtree, and dragging sideways by an indent changes the depth by one.
    func updateDrag(_ id: UUID, location windowLocation: CGPoint, translation: CGSize, indentWidth: CGFloat) {
        guard let index = outline.index(of: id) else { return }
        let end = outline.subtreeEnd(index)
        let movingIDs = drag?.id == id ? drag!.movingIDs : Set(outline.items[index..<end].map(\.id))

        if let target = sidebarTargets().first(where: { $0.key != fileURL && $0.value.contains(windowLocation) })?.key {
            let newDrag = RowDrag(id: id, movingIDs: movingIDs, destination: index, depth: 0, gapY: 0, targetList: target)
            if newDrag != drag { drag = newDrag }
            return
        }

        let location = CGPoint(x: windowLocation.x - outlineOrigin.x, y: windowLocation.y - outlineOrigin.y)
        let rows = outline.visibleIndices(showDecrufted: options.showDecrufted)
            .filter { $0 < index || $0 >= end }
        func frame(_ i: Int) -> CGRect? { rowFrames[outline.items[i].id] }

        let nextPosition = rows.firstIndex { (frame($0)?.midY ?? 0) > location.y }
        let next = nextPosition.map { rows[$0] }
        let previous = (nextPosition ?? rows.count) > 0 ? rows[(nextPosition ?? rows.count) - 1] : nil
        guard let target = outline.dropTarget(moving: index, afterVisible: previous, beforeVisible: next)
        else {
            // Back from the sidebar to a spot it can't drop on: no target.
            if drag?.targetList != nil { drag = nil }
            return
        }

        let wanted = outline.items[index].depth + Int((translation.width / indentWidth).rounded())
        let depth = min(max(wanted, target.depths.lowerBound), target.depths.upperBound)
        let gapY = next.flatMap(frame)?.minY ?? previous.flatMap(frame)?.maxY ?? 0
        let newDrag = RowDrag(id: id, movingIDs: movingIDs, destination: target.destination, depth: depth, gapY: gapY)
        if newDrag != drag { drag = newDrag }
    }

    /// Drops the dragged row where `updateDrag` last put it.
    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        if let target = drag.targetList {
            moveToList(drag.id, target)
            return
        }
        guard let i = outline.index(of: drag.id) else { return }
        mutate { $0.move(at: i, to: drag.destination, depth: drag.depth) }
    }

    /// Moves a task and its subtasks to the end of another list. The other
    /// list is written first, off the main thread (iCloud can stall a write),
    /// and the task is only removed here once that has worked.
    func moveToList(_ id: UUID, _ target: URL) {
        guard let index = outline.index(of: id), !outline.items[index].isHeading else { return }
        let subtree = outline.subtreeItems(at: index)
        Task {
            let error = await Task.detached { () -> String? in
                let store = MarkdownFileStore(fileURL: target)
                do {
                    var other = try store.load()
                    other.appendSubtree(subtree)
                    try store.save(other)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let error {
                errorMessage = "Couldn't move the task to \(target.lastPathComponent): \(error)"
                return
            }
            guard let i = outline.index(of: id) else { return }
            let nextFocus = neighbour(of: id, offset: -1) ?? neighbour(of: id, offset: 1)
            mutate {
                $0.removeSubtree(at: i)
                if $0.isEmpty { $0.appendItem() }
            }
            if focusedID == id { focusedID = nil }
            // The row below may have been one of its subtasks, now gone.
            if let nextFocus, outline.index(of: nextFocus) != nil { requestFocus(nextFocus) }
        }
    }

    func setCollapsed(_ collapsed: Bool, for id: UUID) {
        guard let i = outline.index(of: id), outline.canCollapse(i) else { return }
        mutate { $0.setCollapsed(collapsed, at: i) }
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        setCollapsed(!outline.items[i].isCollapsed, for: id)
    }

    /// Backspace in an empty row: an empty heading becomes a task again;
    /// an empty task is removed and the row above is focused. Rows with
    /// children, and the last remaining row, are kept.
    func deleteIfEmpty(_ id: UUID) {
        if let i = outline.index(of: id), outline.items[i].isHeading {
            makeTask(id)
            return
        }
        guard let i = outline.index(of: id),
              outline.items[i].title.isEmpty,
              !outline.hasChildren(i),
              outline.items.count > 1
        else { return }
        let target = neighbour(of: id, offset: -1) ?? neighbour(of: id, offset: 1)
        mutate { $0.removeSubtree(at: i) }
        if let target { requestFocus(target) }
    }

    func decruft() {
        if UserDefaults.standard.bool(forKey: DisplaySettings.deleteDecrufted) {
            mutate {
                $0.deleteDone()
                if $0.isEmpty { $0.appendItem() }
            }
        } else {
            mutate { $0.decruftDone() }
        }
        if let focusedID, !visibleItems.contains(where: { $0.id == focusedID }) {
            self.focusedID = nil
        }
    }

    // MARK: - Focus

    func requestFocus(_ id: UUID, caret: Int? = nil) {
        focusedID = id
        focusRequestID = id
        focusRequestCaret = caret
    }

    /// Called by a row's text field once it actually has keyboard focus.
    func didFocus(_ id: UUID) {
        focusedID = id
        if focusRequestID == id { focusRequestID = nil }
    }

    func focusFirstRow() {
        if let first = visibleItems.first { requestFocus(first.id) }
    }

    func focusPrevious(from id: UUID) {
        if let target = neighbour(of: id, offset: -1) { requestFocus(target) }
    }

    func focusNext(from id: UUID) {
        if let target = neighbour(of: id, offset: 1) { requestFocus(target) }
    }

    private func neighbour(of id: UUID, offset: Int) -> UUID? {
        let rows = visibleItems
        guard let i = rows.firstIndex(where: { $0.id == id }),
              rows.indices.contains(i + offset)
        else { return nil }
        return rows[i + offset].id
    }

    // MARK: - Loading and saving

    /// Discards in-memory state and re-reads the file (e.g. after editing it elsewhere).
    func reload() {
        pendingSave?.cancel()
        pendingSave = nil
        load()
    }

    private func load() {
        do {
            let text = try store.readText()
            syncedText = text
            outline = text.map(MarkdownCodec.decode) ?? Outline()
        } catch {
            errorMessage = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
            outline = Outline()
        }
        // Always offer a row to type into; it isn't written until edited.
        if outline.isEmpty { outline.appendItem() }
        showsListTitle = outline.title != nil
        focusedID = nil
        focusRequestID = nil
    }

    /// Picks up changes made to the file elsewhere. With no unsaved edits
    /// the list just shows the new contents; otherwise saving now merges
    /// the two versions.
    /// The file is read off the main thread, since iCloud can stall a read
    /// for seconds; if this Mac saved meanwhile, the read is stale and dropped.
    func checkDisk() {
        let store = store
        let before = syncedText
        Task {
            let text = await Task.detached { try? store.readText() }.value
            guard let text, syncedText == before, text != syncedText else { return }
            if pendingSave != nil { saveNow() } else { adopt(text) }
        }
    }

    /// Shows `text`, the file's current contents, in place of the outline.
    /// Rows keep their identities where they match, so the row being edited
    /// keeps its text field and focus.
    private func adopt(_ text: String) {
        syncedText = text
        var updated = MarkdownCodec.decode(text)
        if updated.isEmpty { updated.appendItem() }
        updated.adoptIdentities(from: outline)
        guard updated != outline else { return }
        outline = updated
        if updated.title != nil { showsListTitle = true }
        if let focusedID, outline.index(of: focusedID) == nil { self.focusedID = nil }
        if let focusRequestID, outline.index(of: focusRequestID) == nil { self.focusRequestID = nil }
    }

    private func mutate(_ change: (inout Outline) -> Void) {
        change(&outline)
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Drops unsaved changes, e.g. when the file has vanished and saving
    /// would recreate it at a path the user moved it away from.
    func discardChanges() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    /// Writes immediately if there are unsaved changes. If the file was
    /// changed elsewhere since it was read, the two versions are merged; if
    /// they clash, the other version wins and this one is kept as a copy.
    func saveNow() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        let mine = MarkdownCodec.encode(outline)
        do {
            guard let disk = try store.readText(), disk != syncedText else {
                try store.writeText(mine)
                syncedText = mine
                return
            }
            switch TextMerge.merge(base: syncedText ?? "", mine: mine, theirs: disk) {
            case .merged(let text):
                if text != disk { try store.writeText(text) }
                adopt(text)
            case .conflict:
                let copy = TaskLibrary.conflictCopyURL(for: fileURL)
                try MarkdownFileStore(fileURL: copy).writeText(mine)
                adopt(disk)
                errorMessage = "“\(fileName)” was changed somewhere else while you were editing it here, "
                    + "and the changes clash. It now shows the other version; yours is saved beside it "
                    + "as “\(TaskLibrary.displayName(of: copy))”."
            }
        } catch {
            errorMessage = "Couldn't save \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
