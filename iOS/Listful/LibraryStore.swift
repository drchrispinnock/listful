import Foundation
import Observation
import ListfulCore

/// The folder of task lists the user picked, what's in it, the selection,
/// and the `ListDocument` for whichever list is open. The iOS counterpart
/// of the Mac app's `LibraryModel`.
@MainActor @Observable
final class LibraryStore {
    /// A subfolder of the lists folder, shown as a group with its lists.
    struct Folder: Equatable {
        let url: URL
        var lists: [URL]
        var name: String { url.lastPathComponent }
    }

    enum NamePrompt: Equatable {
        /// A new list in this folder.
        case newList(URL)
        case newFolder
        /// A list, or a subfolder (a URL with a trailing slash).
        case rename(URL)
    }

    private enum Keys {
        static let selectedList = "selectedList"
        static let showDecrufted = "showDecrufted"
    }

    private(set) var folderURL: URL?
    private(set) var lists: [URL] = []
    /// Repeating checklists' templates, from the folder's Templates subfolder.
    private(set) var templates: [URL] = []
    private(set) var subfolders: [Folder] = []
    /// `#` titles read from list files that have one.
    private(set) var titles: [URL: String] = [:]
    /// Lists with nothing left to do; earlier repeating copies like these
    /// are tucked away.
    private(set) var finishedLists: Set<URL> = []
    private(set) var document: ListDocument?
    var selection: URL? {
        didSet {
            guard selection != oldValue else { return }
            openSelection()
            if let oldValue, templates.contains(oldValue) { makeDueCopies() }
        }
    }
    var showDecrufted: Bool {
        didSet { UserDefaults.standard.set(showDecrufted, forKey: Keys.showDecrufted) }
    }
    var collapsedFolders: Set<URL> = []
    var expandedEarlier: Set<URL> = []

    var namePrompt: NamePrompt?
    var nameDraft = ""
    /// A list or folder waiting for the user to confirm moving it to the Trash.
    var pendingTrash: URL?
    var isChoosingFolder = false
    /// Looking up the iCloud Drive folder at launch, before anything shows.
    private(set) var isLocatingFolder = false
    /// True when the lists are in iCloud Drive › Listful rather than a
    /// folder the user chose.
    private(set) var isUsingICloudFolder = false
    var errorMessage: String?

    @ObservationIgnored private var library: TaskLibrary?
    @ObservationIgnored private var templateLibrary: TaskLibrary?
    @ObservationIgnored private var titlesTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isMakingCopies = false
    @ObservationIgnored private var dayObserver: NSObjectProtocol?

    init() {
        showDecrufted = UserDefaults.standard.bool(forKey: Keys.showDecrufted)
        #if DEBUG
        // For trying the app in the simulator without the folder picker:
        // `xcrun simctl launch booted com.chrispinnock.listful -testFolder /some/dir`.
        if let path = UserDefaults.standard.string(forKey: "testFolder") {
            use(URL(filePath: path, directoryHint: .isDirectory), restoring: UserDefaults.standard.string(forKey: Keys.selectedList))
            return
        }
        #endif
        if let url = FolderAccess.restoreChosen() {
            use(url, restoring: UserDefaults.standard.string(forKey: Keys.selectedList))
            // Make iCloud Drive › Listful anyway, so it's there to switch to
            // (and on the Mac, for moving the lists into).
            Task.detached { _ = FolderAccess.iCloudFolder() }
        } else {
            useICloudFolder(restoring: UserDefaults.standard.string(forKey: Keys.selectedList))
        }
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.makeDueCopies() }
        }
    }

    // MARK: - Folder

    /// Uses a folder the user has just picked.
    func choose(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Listful wasn't given access to “\(url.lastPathComponent)”."
            return
        }
        FolderAccess.save(url)
        let previous = folderURL
        use(url, restoring: nil)
        if let previous, previous != url { previous.stopAccessingSecurityScopedResource() }
    }

    /// Goes back to iCloud Drive › Listful from a chosen folder.
    func useICloudFolder() {
        FolderAccess.forgetChosen()
        useICloudFolder(restoring: nil)
    }

    private func useICloudFolder(restoring saved: String?) {
        isLocatingFolder = true
        Task {
            let url = await Task.detached { FolderAccess.iCloudFolder() }.value
            isLocatingFolder = false
            guard let url else {
                if folderURL == nil {
                    errorMessage = "iCloud Drive isn't available. Turn it on in Settings › your name › iCloud, "
                        + "or choose a folder for your task lists."
                }
                return
            }
            let previous = folderURL
            use(url, restoring: saved)
            isUsingICloudFolder = true
            previous?.stopAccessingSecurityScopedResource()
        }
    }

    private func use(_ url: URL, restoring saved: String?) {
        isUsingICloudFolder = false
        closeDocument()
        folderURL = url
        let library = TaskLibrary(folderURL: url)
        self.library = library
        templateLibrary = TaskLibrary(folderURL: library.templatesFolderURL)
        refresh()
        let restored = saved.map { url.appending(path: $0) }
        selection = allLists.first { $0.path == restored?.path }
        makeDueCopies()
    }

    var allLists: [URL] {
        lists + templates + subfolders.flatMap(\.lists)
    }

    /// Re-reads the folder, keeping the selection if its file still exists.
    func refresh() {
        guard let library, let templateLibrary else { return }
        let current = (try? library.lists()) ?? []
        if current != lists { lists = current }
        let currentTemplates = (try? templateLibrary.lists()) ?? []
        if currentTemplates != templates { templates = currentTemplates }
        let currentSubfolders = ((try? library.subfolders()) ?? []).map { url in
            Folder(url: url, lists: (try? TaskLibrary(folderURL: url).lists()) ?? [])
        }
        if currentSubfolders != subfolders { subfolders = currentSubfolders }
        refreshTitles()

        if let selection, !allLists.contains(selection) {
            // Gone (renamed or trashed elsewhere). Saving won't recreate it;
            // unsaved edits are kept in a copy.
            closeDocument()
            self.selection = nil
        }
    }

    private func refreshTitles() {
        let urls = allLists
        titlesTask?.cancel()
        titlesTask = Task {
            let (current, finished) = await Task.detached { Self.readTitles(of: urls) }.value
            guard !Task.isCancelled else { return }
            if current != titles { titles = current }
            if finished != finishedLists { finishedLists = finished }
        }
    }

    /// Also starts downloading lists that are only in iCloud, since reading
    /// a placeholder asks for it.
    nonisolated private static func readTitles(of urls: [URL]) -> ([URL: String], Set<URL>) {
        var titles: [URL: String] = [:]
        var finished: Set<URL> = []
        for url in urls {
            guard let text = try? MarkdownFileStore(fileURL: url).readText() else { continue }
            let outline = MarkdownCodec.decode(text)
            if !RepeatingChecklists.hasOpenTasks(outline) { finished.insert(url) }
            if let title = outline.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                titles[url] = title
            }
        }
        return (titles, finished)
    }

    // MARK: - Coming and going

    /// The app has come to the front: catch up with changes made elsewhere,
    /// make any repeating copies that are due, and keep checking while it's
    /// in front, since iOS gives no reliable notice of changes in iCloud Drive.
    func becameActive() {
        refresh()
        document?.checkDisk()
        makeDueCopies()
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                refresh()
                document?.checkDisk()
            }
        }
    }

    /// The app is going to the background, where it may be stopped at any time.
    func resignedActive() {
        pollTask?.cancel()
        pollTask = nil
        document?.saveNow()
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

    /// A template's copies split into the newest and earlier ones with tasks
    /// left (`shown`), and earlier finished ones.
    func copyGroups(of template: URL) -> (shown: [URL], earlier: [URL]) {
        let all = copies(of: template)
        guard let newest = all.first else { return ([], []) }
        let older = all.dropFirst()
        let isTucked = { (url: URL) in self.finishedLists.contains(url) && url != self.selection }
        return ([newest] + older.filter { !isTucked($0) }, older.filter(isTucked))
    }

    /// A copy's name without its template's, e.g. "Tue 3 Nov".
    func copyLabel(of url: URL, template: URL) -> String {
        let name = displayName(of: url)
        let prefix = displayName(of: template) + " — "
        let label = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        if let (_, duplicate) = RepeatingChecklists.copyKey(of: url, template: TaskLibrary.displayName(of: template)),
           duplicate > 0 {
            return "\(label) (\(duplicate))"
        }
        return label
    }

    /// A list's `#` title (live, for the open one), or else its file name.
    func displayName(of url: URL) -> String {
        if let document, document.fileURL == url { return document.displayTitle }
        return titles[url] ?? TaskLibrary.displayName(of: url)
    }

    // MARK: - Opening

    private func openSelection() {
        document?.saveNow()
        guard let selection, let folderURL else {
            document = nil
            return
        }
        document = ListDocument(fileURL: selection)
        let folderPath = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        let saved = selection.path.hasPrefix(folderPath) ? String(selection.path.dropFirst(folderPath.count)) : nil
        UserDefaults.standard.set(saved, forKey: Keys.selectedList)
    }

    /// Saves and drops the open document, so nothing can write to its file
    /// after it has been renamed or trashed.
    private func closeDocument() {
        document?.saveNow()
        document = nil
    }

    // MARK: - Creating, renaming, trashing

    func promptNewList(in folder: URL? = nil) {
        guard let folderURL else { return }
        let target = folder ?? selection.flatMap(subfolder(containing:))?.url ?? folderURL
        nameDraft = TaskLibrary(folderURL: target).suggestedNewName()
        namePrompt = .newList(target)
    }

    func promptNewFolder() {
        guard let library else { return }
        nameDraft = library.suggestedNewName(base: "New Folder")
        namePrompt = .newFolder
    }

    func promptRename(_ url: URL) {
        nameDraft = url.hasDirectoryPath ? url.lastPathComponent : displayName(of: url)
        namePrompt = .rename(url)
    }

    func subfolder(containing url: URL) -> Folder? {
        subfolders.first { $0.lists.contains(url) }
    }

    /// The folder's name for prompts; nil for the lists folder itself.
    func folderName(_ url: URL) -> String? {
        guard let folderURL else { return nil }
        return url.standardizedFileURL.path == folderURL.standardizedFileURL.path ? nil : url.lastPathComponent
    }

    func commitNamePrompt(_ prompt: NamePrompt) {
        namePrompt = nil
        guard let library else { return }
        do {
            switch prompt {
            case .newList(let folder):
                let owner = owner(ofFolder: folder)
                let url = try owner.createList(named: nameDraft)
                collapsedFolders.remove(folder)
                refresh()
                selection = url
                document?.focusFirstRow()
            case .newFolder:
                let url = try library.createFolder(named: nameDraft)
                refresh()
                collapsedFolders.remove(url)
            case .rename(let url) where url.hasDirectoryPath:
                let selectedName = selection.flatMap {
                    $0.deletingLastPathComponent().path == url.path ? $0.lastPathComponent : nil
                }
                if selectedName != nil { closeDocument() }
                let renamed = try library.renameFolder(at: url, to: nameDraft)
                refresh()
                if let selectedName {
                    selection = nil
                    selection = subfolders.first { $0.url == renamed }?.lists.first { $0.lastPathComponent == selectedName }
                }
            case .rename(let url):
                let wasSelected = selection == url
                if wasSelected { closeDocument() }
                let renamed = try owner(of: url).renameList(at: url, to: nameDraft)
                retitle(renamed, to: nameDraft)
                refresh()
                if wasSelected {
                    selection = nil
                    selection = renamed
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            refresh()
        }
    }

    /// A titled list's title is what's shown, so it's renamed too.
    private func retitle(_ url: URL, to name: String) {
        let store = MarkdownFileStore(fileURL: url)
        guard var outline = try? store.load(), outline.title != nil else { return }
        outline.title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.save(outline)
    }

    func trash(_ url: URL) {
        guard let library else { return }
        let isInside = selection.map { $0 == url || $0.deletingLastPathComponent().path == url.path } ?? false
        if isInside { closeDocument() }
        do {
            if url.hasDirectoryPath {
                try library.trashFolder(at: url)
            } else {
                try owner(of: url).trashList(at: url)
            }
        } catch {
            errorMessage = "Couldn't move “\(url.lastPathComponent)” to the Trash: \(error.localizedDescription)"
        }
        refresh()
        if isInside { selection = nil }
    }

    private func owner(of url: URL) -> TaskLibrary {
        if templates.contains(url), let templateLibrary { return templateLibrary }
        if let folder = subfolder(containing: url) { return TaskLibrary(folderURL: folder.url) }
        return library ?? TaskLibrary(folderURL: url.deletingLastPathComponent())
    }

    private func owner(ofFolder folder: URL) -> TaskLibrary {
        if let library, folder.standardizedFileURL.path == library.folderURL.standardizedFileURL.path { return library }
        return TaskLibrary(folderURL: subfolders.first { $0.url.path == folder.path }?.url ?? folder)
    }

    // MARK: - Repeating checklists

    /// Makes any repeating checklist copies that are due, off the main
    /// thread, and merges away duplicates made on two devices at once.
    func makeDueCopies() {
        guard !isMakingCopies, let templates = templateLibrary, let lists = library else { return }
        isMakingCopies = true
        document?.saveNow()
        let open = selection
        Task {
            let (results, trashed) = await Task.detached {
                let results = RepeatingChecklists.makeDueCopies(
                    templates: templates, lists: lists, date: Date(), calendar: .current, locale: .current)
                let trashed = RepeatingChecklists.mergeDuplicates(templates: templates, lists: lists, keeping: open)
                return (results, trashed)
            }.value
            isMakingCopies = false
            if !results.isEmpty || !trashed.isEmpty { refresh() }
            // A template that's only in iCloud so far is tried again later.
            if let error = results.compactMap(\.error).first(where: { !$0.contains("downloaded") }) {
                errorMessage = error
            }
            if let moved = results.first(where: { $0.copy != nil && $0.previous != nil && $0.previous == selection }) {
                selection = moved.copy
            }
        }
    }
}
