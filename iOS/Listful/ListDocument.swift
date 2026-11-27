import Foundation
import Observation
import ListfulCore

/// One open task list: its outline, id-based edits for the views, and
/// saving and syncing with the file. The iOS counterpart of the Mac app's
/// `TaskDocument`; the rules for merging with changes made elsewhere are
/// shared (`FileSync`).
@MainActor @Observable
final class ListDocument {
    enum LoadState: Equatable {
        case loaded
        /// Waiting for iCloud to bring the file to this device.
        case downloading
        /// The file couldn't be read; nothing is saved until it can be.
        case failed(String)
    }

    private(set) var outline = Outline()
    let fileURL: URL
    private(set) var loadState = LoadState.loaded
    var errorMessage: String?
    /// A one-shot request for a row's text field to take focus.
    var focusRequest: UUID?
    /// The row last edited, which the menus act on.
    var focusedID: UUID?
    /// The row being edited now (keyboard up), which the bar above the
    /// keyboard acts on.
    var editingID: UUID?

    @ObservationIgnored private let store: MarkdownFileStore
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The file's text as last read or written here.
    @ObservationIgnored private var syncedText: String?
    /// For a repeating checklist's copy, how a clash with another device's
    /// version is merged (task by task) instead of making a conflict copy.
    @ObservationIgnored var clashMerge: (@Sendable (String, String) -> String)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isCheckingDisk = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        store = MarkdownFileStore(fileURL: fileURL)
        load()
    }

    var fileName: String { TaskLibrary.displayName(of: fileURL) }

    var displayTitle: String {
        if let title = outline.title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return fileName
    }

    func setListTitle(_ title: String) {
        let newTitle: String? = title.isEmpty ? nil : title
        guard newTitle != outline.title else { return }
        mutate { $0.title = newTitle }
    }

    func visibleItems(showDecrufted: Bool) -> [TaskItem] {
        outline.visibleIndices(showDecrufted: showDecrufted).map { outline.items[$0] }
    }

    func title(of id: UUID) -> String? {
        outline.index(of: id).map { outline.items[$0].title }
    }

    func canCollapse(_ id: UUID) -> Bool {
        outline.index(of: id).map(outline.canCollapse) ?? false
    }

    // MARK: - Editing

    /// Sets a row's text. A line break in it (Return, or pasting several
    /// lines) splits the row there, as Return does on the Mac; each further
    /// line becomes a task of its own. Typing "# " at the start of a task
    /// makes it a heading.
    func setTitle(_ title: String, for id: UUID) {
        guard let i = outline.index(of: id) else { return }
        if let lineBreak = title.firstIndex(where: \.isNewline) {
            let head = String(title[..<lineBreak])
            let tail = String(title[title.index(after: lineBreak)...])
            var newID = id
            mutate {
                $0.setTitle(head + tail, at: i)
                let caret = head.utf16.count
                let target = $0.returnKey(at: i, selection: caret..<caret)
                newID = $0.items[target.index].id
            }
            focusRequest = newID
            // Further lines (a paste) split again from the new row.
            if tail.contains(where: \.isNewline), let j = outline.index(of: newID) {
                setTitle(outline.items[j].title, for: newID)
            }
            return
        }
        let old = outline.items[i]
        guard old.title != title else { return }
        if !old.isHeading, let heading = MarkdownCodec.parseHeading(title) {
            let prefix = String(repeating: "#", count: heading.level) + " "
            if title.hasPrefix(prefix) && !old.title.hasPrefix(prefix) {
                mutate {
                    let index = $0.makeHeading(level: heading.level, at: i)
                    $0.setTitle(heading.text, at: index)
                }
                return
            }
        }
        mutate { $0.setTitle(title, at: i) }
    }

    func appendTask() {
        var newIndex = 0
        mutate { newIndex = $0.appendItem() }
        focusRequest = outline.items[newIndex].id
    }

    func focusFirstRow() {
        focusRequest = outline.items.first?.id
    }

    func toggleDone(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.toggleDone(at: i) }
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = outline.index(of: id), outline.canCollapse(i) else { return }
        let collapsed = !outline.items[i].isCollapsed
        mutate { $0.setCollapsed(collapsed, at: i) }
    }

    func indent(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.indent(at: i) }
    }

    func outdent(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.outdent(at: i) }
    }

    func moveUp(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.moveUp(at: i) }
    }

    func moveDown(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.moveDown(at: i) }
    }

    func makeHeading(_ level: Int, for id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.makeHeading(level: level, at: i) }
    }

    func makeTask(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate { $0.makeTask(at: i) }
    }

    /// Deletes the task and its subtasks (or a heading, keeping its section).
    func delete(_ id: UUID) {
        guard let i = outline.index(of: id) else { return }
        mutate {
            $0.removeSubtree(at: i)
            if $0.isEmpty { $0.appendItem() }
        }
        if focusedID == id { focusedID = nil }
    }

    /// Sorts A–Z the level the task is on (see `Outline.sortRange`), or the
    /// top level with no task given.
    func sort(_ id: UUID?) {
        guard !outline.isEmpty else { return }
        let i = id.flatMap(outline.index(of:)) ?? 0
        var sorted = outline
        guard sorted.sortTasks(for: i) else { return }
        mutate { $0 = sorted }
    }

    /// Deletes done (and older decrufted) tasks, keeping open subtasks.
    func decruft() {
        mutate {
            $0.deleteDone()
            if $0.isEmpty { $0.appendItem() }
        }
    }

    /// A row dragged in the list, from one visible position to another (as
    /// `List.onMove` reports them). It takes its subtasks with it and keeps
    /// its depth where it can.
    func moveVisibleRow(from source: Int, to destination: Int, showDecrufted: Bool) {
        let visible = outline.visibleIndices(showDecrufted: showDecrufted)
        guard visible.indices.contains(source) else { return }
        let index = visible[source]
        let end = outline.subtreeEnd(index)
        guard !outline.items[index].isHeading else { return }
        let others = visible.enumerated().filter { $0.element < index || $0.element >= end }
        // The rows either side of the gap, ignoring the moved row's subtree.
        let next = others.first { $0.offset >= destination }?.element
        let previous = others.last { $0.offset < destination }?.element
        guard let target = outline.dropTarget(moving: index, afterVisible: previous, beforeVisible: next) else { return }
        let depth = min(max(outline.items[index].depth, target.depths.lowerBound), target.depths.upperBound)
        mutate { $0.move(at: index, to: target.destination, depth: depth) }
    }

    // MARK: - Loading and saving

    func reload() {
        pendingSave?.cancel()
        pendingSave = nil
        load()
    }

    /// Reads the file: straight away if it's on this device, otherwise off
    /// the main thread while it downloads, showing it as downloading.
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
            outline = Outline()
            loadState = .downloading
        case .failure(let error):
            outline = Outline()
            loadState = .failed("Couldn't read “\(fileURL.lastPathComponent)”: \(error.localizedDescription)")
        }
        if outline.isEmpty { outline.appendItem() }
        focusedID = nil
        focusRequest = nil
    }

    /// Picks up changes made elsewhere. With no unsaved edits the list just
    /// shows the new text; otherwise saving merges the two.
    func checkDisk() {
        guard loadState == .loaded else {
            if loadTask == nil { load() }
            return
        }
        guard !isCheckingDisk else { return }
        isCheckingDisk = true
        let store = store
        let before = syncedText
        Task {
            let text = await Task.detached { try? store.readText() }.value
            isCheckingDisk = false
            guard let text, syncedText == before, text != syncedText else { return }
            if pendingSave != nil { saveNow() } else { adopt(text) }
        }
    }

    /// Shows the file's current text, keeping rows' identities where they
    /// match so the row being edited keeps its focus.
    private func adopt(_ text: String) {
        syncedText = text
        var updated = MarkdownCodec.decode(text)
        if updated.isEmpty { updated.appendItem() }
        updated.adoptIdentities(from: outline)
        guard updated != outline else { return }
        outline = updated
        if let focusedID, outline.index(of: focusedID) == nil { self.focusedID = nil }
    }

    private func mutate(_ change: (inout Outline) -> Void) {
        change(&outline)
        scheduleSave()
    }

    private func scheduleSave() {
        guard loadState == .loaded else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes now if there are unsaved changes, merging with any made elsewhere.
    func saveNow() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        let mine = MarkdownCodec.encode(outline)
        do {
            switch try FileSync.save(mine, to: store, synced: syncedText, clashMerge: clashMerge) {
            case .saved(let text):
                syncedText = text
            case .merged(let text):
                adopt(text)
            case .conflict(let disk, let copy):
                adopt(disk)
                errorMessage = "“\(fileName)” was changed somewhere else while you were editing it here, "
                    + "and the changes clash. It now shows the other version; yours is saved beside it "
                    + "as “\(TaskLibrary.displayName(of: copy))”."
            case .gone(let copy):
                if let copy {
                    errorMessage = "“\(fileName)” was renamed or deleted somewhere else while you were editing it here. "
                        + "Your latest changes are saved as “\(TaskLibrary.displayName(of: copy))”."
                }
            }
        } catch {
            errorMessage = "Couldn't save \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
