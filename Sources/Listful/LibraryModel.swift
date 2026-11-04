import AppKit
import Observation
import ListfulCore
import UniformTypeIdentifiers

/// The folder of task lists shown in the sidebar, the current selection, and
/// the `TaskDocument` for whichever list is open.
@MainActor @Observable
final class LibraryModel {
    enum NamePrompt: Equatable {
        case newList
        case rename(URL)
    }

    private enum Keys {
        static let folder = "libraryFolder"
        static let selectedList = "selectedList"
        static let linkedFiles = "linkedFiles"
    }

    /// Extensions accepted when adding files from elsewhere.
    static let linkableExtensions: Set<String> = ["md", "markdown", "txt"]

    static var defaultFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Task Lists")
    }

    let options = ViewOptions()
    private(set) var folderURL: URL
    private(set) var lists: [URL] = []
    /// Repeating checklists' templates, from the folder's Templates subfolder.
    private(set) var templates: [URL] = []
    /// Task list files outside the folder, edited in place. Persisted as paths.
    private(set) var linkedFiles: [URL] = []
    /// Linked files that no longer exist at their saved path.
    private(set) var missingFiles: Set<URL> = []
    /// `#` titles read from list files that have one.
    private(set) var titles: [URL: String] = [:]
    /// Lists with nothing left to do; earlier repeating copies like these
    /// are tucked away in the sidebar.
    private(set) var finishedLists: Set<URL> = []
    /// Sidebar disclosure state for repeating checklists: templates folded
    /// away, and templates whose finished earlier copies are shown.
    var collapsedTemplates: Set<URL> = []
    var expandedEarlier: Set<URL> = []
    private(set) var document: TaskDocument?
    var selection: URL? {
        didSet {
            guard selection != oldValue else { return }
            openSelection()
            // Leaving a template is when a newly written one first gets copied.
            if let oldValue, templates.contains(oldValue) { makeDueCopies() }
        }
    }

    /// When set, the sidebar shows a name field for creating or renaming a list.
    var namePrompt: NamePrompt?
    var nameDraft = ""
    /// A list waiting for the user to confirm moving it to the Trash.
    var pendingTrash: URL?
    /// When true, the sheet for a new repeating checklist is shown,
    /// editing `nameDraft` and `scheduleDraft`.
    var isCreatingRepeating = false
    var scheduleDraft = RepeatSchedule()
    var errorMessage: String?

    @ObservationIgnored private var library: TaskLibrary
    @ObservationIgnored private var templateLibrary: TaskLibrary
    @ObservationIgnored private var folderWatchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var titlesTask: Task<Void, Never>?
    @ObservationIgnored private var dayObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var isMakingCopies = false
    @ObservationIgnored private var needsCopiesAgain = false

    init() {
        let folder = UserDefaults.standard.url(forKey: Keys.folder) ?? Self.defaultFolderURL
        folderURL = folder
        library = TaskLibrary(folderURL: folder)
        templateLibrary = TaskLibrary(folderURL: library.templatesFolderURL)
        linkedFiles = (UserDefaults.standard.stringArray(forKey: Keys.linkedFiles) ?? [])
            .map { URL(filePath: $0) }
        loadFolder(restoring: UserDefaults.standard.string(forKey: Keys.selectedList))

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.document?.saveNow() }
        }
        // Linked files live in folders we don't watch, so re-check them
        // whenever the user comes back to the app. The open list is checked
        // too, in case its file watcher missed a change.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLists()
                self?.document?.checkDisk()
                self?.makeDueCopies()
            }
        }
        // A new day or a wake from sleep can start a repeating checklist's
        // next period while the app is already in front.
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.makeDueCopies() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.makeDueCopies() }
        }
    }

    // MARK: - Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder that holds your task lists."
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }

        closeDocument()
        folderURL = url
        library = TaskLibrary(folderURL: url)
        templateLibrary = TaskLibrary(folderURL: library.templatesFolderURL)
        UserDefaults.standard.set(url, forKey: Keys.folder)
        loadFolder(restoring: nil)
    }

    func revealInFinder(_ url: URL? = nil) {
        if let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(folderURL)
        }
    }

    private func loadFolder(restoring selectedName: String?) {
        do {
            try library.ensureFolderExists()
        } catch {
            errorMessage = "Couldn't create \(folderURL.path(percentEncoded: false)): \(error.localizedDescription)"
        }
        // A linked file that's now inside the folder is listed there instead.
        setLinkedFiles(linkedFiles.filter { !library.contains($0) })
        refreshLists()
        watchFolder()
        // The saved selection is a file name for folder lists, a full path for linked files.
        let restored = selectedName.map { $0.hasPrefix("/") ? URL(filePath: $0) : folderURL.appending(path: $0) }
        selection = (lists + templates + linkedFiles).first { $0 == restored } ?? lists.first
        makeDueCopies()
    }

    /// Re-reads the folder and re-checks linked files, keeping the selection
    /// if its file still exists.
    func refreshLists() {
        let current = (try? library.lists()) ?? []
        if current != lists { lists = current }
        let currentTemplates = (try? templateLibrary.lists()) ?? []
        if currentTemplates != templates { templates = currentTemplates }
        let missing = Set(linkedFiles.filter { !FileManager.default.fileExists(atPath: $0.path) })
        if missing != missingFiles { missingFiles = missing }
        refreshTitles()

        guard let selection else { return }
        if missing.contains(selection) {
            // Keep it selected so the detail pane can say what happened, but
            // don't save: that would recreate the file where it used to be.
            if document != nil { dropDocument(saving: false) }
        } else if !current.contains(selection) && !currentTemplates.contains(selection) && !linkedFiles.contains(selection) {
            dropDocument(saving: false)
            self.selection = nil
        } else if document == nil {
            // A missing linked file has come back.
            openSelection()
        }
    }

    /// Refreshes the sidebar when files are added, removed or renamed in the
    /// folder or its Templates subfolder by anything, including Finder.
    private func watchFolder() {
        folderWatchers.forEach { $0.cancel() }
        folderWatchers = [folderURL, templateLibrary.folderURL].compactMap { url in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.refreshLists() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    /// Re-reads each list's `#` title, and which lists are finished. Lists
    /// are small, but a read can stall for seconds while iCloud syncs the
    /// file, so it's done off the main thread; a newer refresh supersedes
    /// one still running.
    private func refreshTitles() {
        let urls = (lists + templates + linkedFiles).filter { !missingFiles.contains($0) }
        titlesTask?.cancel()
        titlesTask = Task {
            let (current, finished) = await Task.detached { Self.readTitles(of: urls) }.value
            guard !Task.isCancelled else { return }
            if current != titles { titles = current }
            if finished != finishedLists { finishedLists = finished }
        }
    }

    nonisolated private static func readTitles(of urls: [URL]) -> ([URL: String], Set<URL>) {
        var titles: [URL: String] = [:]
        var finished: Set<URL> = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let outline = MarkdownCodec.decode(text)
            if !RepeatingChecklists.hasOpenTasks(outline) { finished.insert(url) }
            if let title = outline.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                titles[url] = title
            }
        }
        return (titles, finished)
    }

    // MARK: - Sidebar groups

    /// The folder's lists that aren't copies of a repeating checklist.
    var ungroupedLists: [URL] {
        let grouped = Set(templates.flatMap(copies(of:)))
        return lists.filter { !grouped.contains($0) }
    }

    /// A template's copies, newest first.
    func copies(of template: URL) -> [URL] {
        RepeatingChecklists.copies(ofTemplateNamed: TaskLibrary.displayName(of: template), in: lists)
    }

    /// A template's copies split for the sidebar: the newest, earlier ones
    /// with tasks left, and earlier finished ones. The open list always
    /// counts as shown, so it doesn't vanish when its last task is ticked.
    func copyGroups(of template: URL) -> (shown: [URL], earlier: [URL]) {
        let all = copies(of: template)
        guard let newest = all.first else { return ([], []) }
        let older = all.dropFirst()
        let isTucked = { (url: URL) in self.finishedLists.contains(url) && url != self.selection }
        return ([newest] + older.filter { !isTucked($0) }, older.filter(isTucked))
    }

    /// A copy's sidebar name without its template's name, e.g. "Tue 3 Nov".
    func copyLabel(of url: URL, template: URL) -> String {
        let name = displayName(of: url)
        let prefix = displayName(of: template) + " — "
        return name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
    }

    /// The sidebar name for a list: its `#` title (live, for the open list)
    /// or else the file name.
    func displayName(of url: URL) -> String {
        if let document, document.fileURL == url { return document.displayTitle }
        return titles[url] ?? TaskLibrary.displayName(of: url)
    }

    // MARK: - Opening

    private func openSelection() {
        document?.saveNow()
        guard let selection, !missingFiles.contains(selection) else {
            document = nil
            return
        }
        document = TaskDocument(fileURL: selection, options: options)
        let isLinked = linkedFiles.contains(selection)
        UserDefaults.standard.set(isLinked ? selection.path : selection.lastPathComponent, forKey: Keys.selectedList)
    }

    /// Saves and drops the open document, so that nothing can write to its
    /// file after it has been renamed or trashed.
    private func closeDocument() {
        dropDocument(saving: true)
    }

    private func dropDocument(saving: Bool) {
        if saving { document?.saveNow() } else { document?.discardChanges() }
        document = nil
    }

    // MARK: - Files from elsewhere

    func isLinked(_ url: URL) -> Bool {
        linkedFiles.contains(url)
    }

    func addExistingFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.linkableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        panel.message = "Choose task list files to show in the sidebar. They stay where they are and are edited in place."
        guard panel.runModal() == .OK else { return }
        link(panel.urls)
    }

    /// Adds files to the sidebar and selects the last one. Files already in
    /// the folder or already linked are just selected. Returns whether any
    /// of the URLs was usable.
    @discardableResult
    func link(_ urls: [URL]) -> Bool {
        var toSelect: URL?
        var added = linkedFiles
        for url in urls where url.isFileURL && !url.hasDirectoryPath {
            let url = url.standardizedFileURL
            guard Self.linkableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let owner = [library, templateLibrary].first(where: { $0.contains(url) }) {
                toSelect = owner.canonicalURL(for: url)
                continue
            }
            if !added.contains(url) { added.append(url) }
            toSelect = url
        }
        setLinkedFiles(added)
        refreshLists()
        if let toSelect { selection = toSelect }
        return toSelect != nil
    }

    /// Points a missing linked file's sidebar entry at its new location.
    func relocate(_ missing: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.linkableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Use File"
        panel.message = "Where is “\(missing.lastPathComponent)” now?"
        panel.directoryURL = missing.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLinkedFiles(linkedFiles.filter { $0 != missing })
        if !link([url]) {
            errorMessage = "“\(url.lastPathComponent)” isn't a Markdown or text file."
        }
    }

    /// Removes a linked file from the sidebar. The file itself is untouched.
    func unlink(_ url: URL) {
        let wasSelected = selection == url
        if wasSelected { closeDocument() }
        setLinkedFiles(linkedFiles.filter { $0 != url })
        refreshLists()
        if wasSelected { selection = lists.first ?? linkedFiles.first }
    }

    private func setLinkedFiles(_ urls: [URL]) {
        let sorted = urls.sorted {
            TaskLibrary.displayName(of: $0).localizedStandardCompare(TaskLibrary.displayName(of: $1)) == .orderedAscending
        }
        if sorted != linkedFiles { linkedFiles = sorted }
        UserDefaults.standard.set(sorted.map(\.path), forKey: Keys.linkedFiles)
    }

    // MARK: - Creating, renaming, trashing

    func promptNewList() {
        nameDraft = library.suggestedNewName()
        namePrompt = .newList
    }

    func promptRename(_ url: URL) {
        nameDraft = displayName(of: url)
        namePrompt = .rename(url)
    }

    func commitNamePrompt(_ prompt: NamePrompt) {
        namePrompt = nil
        do {
            switch prompt {
            case .newList:
                let url = try library.createList(named: nameDraft)
                refreshLists()
                selection = url
                document?.focusFirstRow()
            case .rename(let url):
                let wasSelected = selection == url
                if wasSelected { closeDocument() }
                let renamed = try owner(of: url).renameList(at: url, to: nameDraft)
                retitle(renamed, to: nameDraft)
                refreshLists()
                if wasSelected {
                    // Clear first so the didSet reopens even if the URL is unchanged.
                    selection = nil
                    selection = renamed
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            refreshLists()
            if selection != nil && document == nil { openSelection() }
        }
    }

    /// Renaming changes what the sidebar shows, so a list with a `#` title
    /// gets the new name as its title too (the file name alone wouldn't show).
    private func retitle(_ url: URL, to name: String) {
        let store = MarkdownFileStore(fileURL: url)
        guard var outline = try? store.load(), outline.title != nil else { return }
        outline.title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.save(outline)
        } catch {
            errorMessage = "Renamed the file, but couldn't update its title: \(error.localizedDescription)"
        }
    }

    /// Asks before trashing: a whole list is too much to lose to a stray
    /// Delete key press, even though the Trash can give it back.
    func confirmTrash(_ url: URL) {
        pendingTrash = url
    }

    func trash(_ url: URL) {
        let wasSelected = selection == url
        let neighbour = wasSelected ? neighbourInList(of: url) : nil
        if wasSelected { closeDocument() }
        do {
            try owner(of: url).trashList(at: url)
        } catch {
            errorMessage = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
        }
        refreshLists()
        if wasSelected { selection = neighbour.flatMap { lists.contains($0) ? $0 : nil } ?? lists.first }
    }

    private func neighbourInList(of url: URL) -> URL? {
        let siblings = templates.contains(url) ? templates : lists
        guard let i = siblings.firstIndex(of: url) else { return nil }
        if i + 1 < siblings.count { return siblings[i + 1] }
        return i > 0 ? siblings[i - 1] : nil
    }

    /// The folder a list belongs to: the lists folder or the templates one.
    private func owner(of url: URL) -> TaskLibrary {
        templates.contains(url) ? templateLibrary : library
    }

    // MARK: - Repeating checklists

    func promptNewRepeating() {
        nameDraft = templateLibrary.suggestedNewName(base: "Checklist")
        scheduleDraft = RepeatSchedule()
        isCreatingRepeating = true
    }

    /// Creates the template, titled with its name, and opens it to be filled
    /// in. Its first copy is made once it has tasks and the user moves on.
    func commitNewRepeating() {
        isCreatingRepeating = false
        do {
            let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            try templateLibrary.ensureFolderExists()
            let url = try templateLibrary.createList(named: name, contents: Outline(title: name, schedule: scheduleDraft))
            watchFolder()
            refreshLists()
            selection = url
            document?.focusFirstRow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Makes any repeating checklist copies that are due, off the main
    /// thread. If the open list was the previous copy, the new one is opened
    /// in its place. Overlapping requests run once more afterwards.
    func makeDueCopies() {
        guard !isMakingCopies else {
            needsCopiesAgain = true
            return
        }
        isMakingCopies = true
        // Save first, so tasks being carried over include the latest edits.
        document?.saveNow()
        let templates = templateLibrary, lists = library
        Task {
            let results = await Task.detached {
                RepeatingChecklists.makeDueCopies(
                    templates: templates, lists: lists, date: Date(), calendar: .current, locale: .current)
            }.value
            isMakingCopies = false
            if !results.isEmpty { refreshLists() }
            if let error = results.compactMap(\.error).first { errorMessage = error }
            if let moved = results.first(where: { $0.copy != nil && $0.previous != nil && $0.previous == selection }) {
                collapsedTemplates.remove(moved.template)
                selection = moved.copy
            }
            if needsCopiesAgain {
                needsCopiesAgain = false
                makeDueCopies()
            }
        }
    }
}
