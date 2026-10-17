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
    var errorMessage: String?

    @ObservationIgnored private let store: TaskStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(fileURL: URL, options: ViewOptions) {
        self.fileURL = fileURL
        self.options = options
        store = MarkdownFileStore(fileURL: fileURL)
        load()
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
        mutate { $0.title = newTitle }
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

    func insertTask(after id: UUID) {
        guard let i = outline.index(of: id) else { return }
        var newIndex = 0
        mutate { newIndex = $0.insertItem(after: i) }
        requestFocus(outline.items[newIndex].id)
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
        mutate { $0.decruftDone() }
        if let focusedID, !visibleItems.contains(where: { $0.id == focusedID }) {
            self.focusedID = nil
        }
    }

    // MARK: - Focus

    func requestFocus(_ id: UUID) {
        focusedID = id
        focusRequestID = id
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
            outline = try store.load()
        } catch {
            errorMessage = "Couldn't read \(fileURL.lastPathComponent): \(error.localizedDescription)"
            outline = Outline()
        }
        // Always offer a row to type into; it isn't written until edited.
        if outline.isEmpty { outline.appendItem() }
        focusedID = nil
        focusRequestID = nil
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

    /// Writes immediately if there are unsaved changes.
    func saveNow() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        do {
            try store.save(outline)
        } catch {
            errorMessage = "Couldn't save \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
