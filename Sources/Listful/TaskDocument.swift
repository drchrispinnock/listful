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

    enum LoadState: Equatable {
        case loaded
        /// Waiting for iCloud to bring the file to this Mac.
        case downloading
        /// The file couldn't be read; nothing is saved until it can be.
        case failed(String)
    }
    /// Until this is `.loaded` the outline isn't the file's, so it's neither
    /// shown nor saved: saving it would replace the list with an empty one.
    private(set) var loadState = LoadState.loaded

    @ObservationIgnored private let store: MarkdownFileStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The file's text as last read or written here. If the file no longer
    /// matches it, someone else (another app, or another Mac via iCloud)
    /// has changed it.
    @ObservationIgnored private var syncedText: String?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

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

    /// Sorts A–Z the task and its siblings, or a heading's tasks (see
    /// `Outline.sortRange`); with no task given, the top level. Collapsed
    /// rows stay collapsed.
    func sort(_ id: UUID?) {
        guard !outline.isEmpty else { return }
        let i = id.flatMap(outline.index(of:)) ?? 0
        var sorted = outline
        guard sorted.sortTasks(for: i) else { return }
        mutate { $0 = sorted }
        if let id { requestFocus(id) }
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

    /// Delete at the start of a row. A heading becomes a task again. A
    /// task joins the row above: its text is appended there, with the caret
    /// where they meet, and its subtasks go with it. On the first row, an
    /// empty task is removed if there are others.
    func deleteAtStart(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        if outline.items[i].isHeading {
            makeTask(id)
            return
        }
        guard let previousID = neighbour(of: id, offset: -1),
              let previous = outline.index(of: previousID)
        else {
            guard outline.items[i].title.isEmpty, !outline.hasChildren(i), outline.items.count > 1 else { return }
            let next = neighbour(of: id, offset: 1)
            mutate { $0.removeSubtree(at: i) }
            if let next { requestFocus(next) }
            return
        }
        var caret = 0
        mutate { caret = $0.join(i, into: previous) }
        requestFocus(previousID, caret: caret)
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

    // MARK: - Selecting rows

    /// A run of selected rows, from where selecting started (`selectionAnchor`)
    /// to the end that moves (`selectionHead`). Both nil while editing text.
    private(set) var selectionAnchor: UUID?
    private(set) var selectionHead: UUID?
    /// A one-shot request for the outline's key handler to take keyboard
    /// focus, so keys act on the selected rows rather than one row's text.
    var selectionFocusRequested = false

    var hasSelection: Bool { selectionAnchor != nil }

    /// The selected rows, top to bottom.
    var selectedIDs: [UUID] {
        guard let selectionAnchor, let selectionHead else { return [] }
        let rows = visibleItems
        guard let a = rows.firstIndex(where: { $0.id == selectionAnchor }),
              let b = rows.firstIndex(where: { $0.id == selectionHead })
        else { return [] }
        return rows[min(a, b)...max(a, b)].map(\.id)
    }

    /// Everything the selection covers, including what's hidden under the
    /// selected rows.
    private var selectedRange: Range<Int>? {
        let ids = selectedIDs
        guard let first = ids.first.flatMap(outline.index(of:)),
              let last = ids.last.flatMap(outline.index(of:))
        else { return nil }
        return outline.blockRange(from: first, to: last)
    }

    /// Selects one row, ending any text editing.
    func select(_ id: UUID) {
        selectionAnchor = id
        selectionHead = id
        focusedID = id
        focusRequestID = nil
        selectionFocusRequested = true
    }

    /// Extends the selection to `id`, starting it from the row being edited.
    func extendSelection(to id: UUID) {
        if selectionAnchor == nil { selectionAnchor = focusedID ?? id }
        selectionHead = id
        focusedID = id
        focusRequestID = nil
        selectionFocusRequested = true
    }

    /// Shift-Up/Down: grows or shrinks the selection a row at a time.
    func extendSelection(by offset: Int) {
        guard let from = selectionHead ?? focusedID else { return }
        if let target = neighbour(of: from, offset: offset) {
            extendSelection(to: target)
        } else if !hasSelection {
            select(from)
        }
    }

    /// Up/Down with rows selected: selects the single row above or below.
    func moveSelection(by offset: Int) {
        let ids = selectedIDs
        guard let edge = offset < 0 ? ids.first : ids.last else { return }
        select(neighbour(of: edge, offset: offset) ?? edge)
    }

    func selectAll() {
        let rows = visibleItems
        guard let first = rows.first, let last = rows.last else { return }
        select(first.id)
        extendSelection(to: last.id)
    }

    func clearSelection() {
        selectionAnchor = nil
        selectionHead = nil
    }

    /// Return or Escape with rows selected: goes back to editing text, in
    /// the row the selection ended on.
    func editSelection() {
        guard let id = selectionHead else { return }
        requestFocus(id)
    }

    func copySelection() {
        guard let range = selectedRange else { return }
        let block = outline.blockItems(range)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(TaskClipboard.plainText(block), forType: .string)
        pasteboard.setString(TaskClipboard.markdown(block), forType: Self.tasksType)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Deletes the selected rows, with everything under them, and goes on
    /// editing the row above.
    func deleteSelection() {
        let ids = selectedIDs
        guard let range = selectedRange, let first = ids.first, let last = ids.last else { return }
        let target = neighbour(of: first, offset: -1) ?? neighbour(of: last, offset: 1)
        clearSelection()
        mutate {
            $0.removeBlock(range)
            if $0.isEmpty { $0.appendItem() }
        }
        if let target, outline.index(of: target) != nil {
            requestFocus(target)
        } else {
            focusFirstRow()
        }
    }

    /// Pastes in place of the selected rows.
    func pasteOverSelection() {
        guard let range = selectedRange,
              let text = NSPasteboard.general.string(forType: .string)
        else { return }
        let block = pastedBlock(text)
        guard !block.isEmpty else { return }
        clearSelection()
        var pasted = 0..<0
        mutate { pasted = $0.replaceBlock(range, with: block) }
        focusLastVisible(in: pasted)
    }

    /// Pastes several lines of text (or copied rows) as tasks after the row
    /// `id`, or in place of it if it's empty.
    func pasteRows(_ text: String, at id: UUID) {
        guard let i = outline.index(of: id) else { return }
        let block = pastedBlock(text)
        guard !block.isEmpty else { return }
        var pasted = 0..<0
        mutate { pasted = $0.insertBlock(block, at: i) }
        focusLastVisible(in: pasted)
    }

    /// Done if any selected task is open; otherwise all open again.
    func toggleSelectionDone() {
        let indices = selectedIDs.compactMap(outline.index(of:))
        let done = indices.contains { !outline.items[$0].isHeading && outline.items[$0].state == .open }
        mutate { $0.setDone(done, at: indices) }
    }

    /// Indents the selected rows that aren't under another selected row,
    /// stopping at the first that can't be indented.
    func indentSelection() {
        let roots = selectionRoots
        mutate { outline in
            for id in roots {
                guard let i = outline.index(of: id), outline.indent(at: i) else { break }
            }
        }
    }

    /// Outdents the selected rows that aren't under another selected row.
    /// Last first, so they keep their order.
    func outdentSelection() {
        let roots = selectionRoots
        mutate { outline in
            for id in roots.reversed() {
                if let i = outline.index(of: id) { outline.outdent(at: i) }
            }
        }
    }

    private var selectionRoots: [UUID] {
        let ids = selectedIDs
        let selected = Set(ids)
        return ids.filter { id in
            guard let i = outline.index(of: id), let parent = outline.parentIndex(i) else { return true }
            return !selected.contains(outline.items[parent].id)
        }
    }

    static let tasksType = NSPasteboard.PasteboardType(TaskClipboard.typeIdentifier)

    /// Rows from pasted text. If it's what Listful copied, its own Markdown
    /// is used instead, which keeps done and collapsed states.
    private func pastedBlock(_ text: String) -> [TaskItem] {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == text,
           let markdown = pasteboard.string(forType: Self.tasksType) {
            return TaskClipboard.items(from: markdown)
        }
        return TaskClipboard.items(from: text)
    }

    private func focusLastVisible(in range: Range<Int>) {
        let ids = Set(outline.items[range].map(\.id))
        if let last = visibleItems.last(where: { ids.contains($0.id) }) { requestFocus(last.id) }
    }

    // MARK: - Focus

    func requestFocus(_ id: UUID, caret: Int? = nil) {
        clearSelection()
        focusedID = id
        focusRequestID = id
        focusRequestCaret = caret
    }

    /// Called by a row's text field once it actually has keyboard focus.
    func didFocus(_ id: UUID) {
        clearSelection()
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

    /// Reads the file, straight away if it's on this Mac. One that's only in
    /// iCloud is read off the main thread, since the read waits for the
    /// download; meanwhile the list shows as downloading.
    private func load() {
        loadTask?.cancel()
        loadTask = nil
        guard store.needsDownload else {
            finishLoading(Result { try store.readText() })
            return
        }
        loadState = .downloading
        let store = store
        loadTask = Task {
            let result = await Task.detached { Result { try store.readText() } }.value
            guard !Task.isCancelled else { return }
            loadTask = nil
            finishLoading(result)
        }
    }

    private func finishLoading(_ result: Result<String?, Error>) {
        switch result {
        case .success(let text):
            syncedText = text
            outline = text.map(MarkdownCodec.decode) ?? Outline()
            loadState = .loaded
        case .failure(MarkdownFileStoreError.notDownloaded):
            // Only a placeholder so far; the watcher retries once it arrives.
            outline = Outline()
            loadState = .downloading
        case .failure(let error):
            outline = Outline()
            loadState = .failed("Couldn't read “\(fileURL.lastPathComponent)”: \(error.localizedDescription)")
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
        guard loadState == .loaded else {
            if loadTask == nil { load() }
            return
        }
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
        guard loadState == .loaded else { return }
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
            guard let disk = try store.readText() else {
                if let syncedText {
                    // The file was here and has gone: renamed or moved to the
                    // Trash, perhaps on another Mac. Writing it would bring it
                    // back under its old name, so unsaved edits go in a copy.
                    if mine != syncedText { keepAsCopy(mine, because: "was renamed or deleted somewhere else") }
                    return
                }
                try store.writeText(mine)
                syncedText = mine
                return
            }
            guard disk != syncedText else {
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

    /// Writes `text` beside the file as a conflict copy, and says why.
    private func keepAsCopy(_ text: String, because reason: String) {
        let copy = TaskLibrary.conflictCopyURL(for: fileURL)
        do {
            try MarkdownFileStore(fileURL: copy).writeText(text)
            errorMessage = "“\(fileName)” \(reason) while you were editing it here. "
                + "Your latest changes are saved as “\(TaskLibrary.displayName(of: copy))”."
        } catch {
            errorMessage = "“\(fileName)” \(reason), and your latest changes couldn't be saved: "
                + error.localizedDescription
        }
    }
}
