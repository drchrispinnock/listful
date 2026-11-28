import AppKit
import Observation
import ListfulCore
import UniformTypeIdentifiers

/// The folder of task lists shown in the sidebar, the current selection, and
/// the `TaskDocument` for whichever list is open.
@MainActor @Observable
final class LibraryModel {
    enum NamePrompt: Equatable {
        /// A new list in this folder.
        case newList(URL)
        case newFolder
        /// A list, or a subfolder (a URL with a trailing slash).
        case rename(URL)
    }

    /// A folder of lists shown as a group in the sidebar: a subfolder of
    /// the lists folder, or a linked folder from anywhere else.
    struct FolderGroup: Equatable {
        /// With a trailing slash, as everywhere a folder is selected or keyed.
        let url: URL
        var lists: [URL]
        let isLinked: Bool
        var isMissing = false
        var name: String { url.lastPathComponent }
        var library: TaskLibrary { TaskLibrary(folderURL: url) }
    }

    private enum Keys {
        static let folder = "libraryFolder"
        static let selectedList = "selectedList"
        static let linkedFiles = "linkedFiles"
        static let linkedFolders = "linkedFolders"
        static let declinedICloudMove = "declinedICloudMove"
    }

    /// Extensions accepted when adding files from elsewhere.
    static let linkableExtensions: Set<String> = ["md", "markdown", "txt"]

    /// Where the lists were kept before 0.6, and still the starting point
    /// until `checkICloudFolder` moves them (or finds them moved) to
    /// iCloud Drive › Listful.
    static var defaultFolderURL: URL { ListsMigration.legacyFolderURL() }

    let options = ViewOptions()
    private(set) var folderURL: URL
    private(set) var lists: [URL] = []
    /// Repeating checklists' templates, from the folder's Templates subfolder.
    private(set) var templates: [URL] = []
    /// Task list files outside the folder, edited in place. Persisted as paths.
    private(set) var linkedFiles: [URL] = []
    /// Linked files that no longer exist at their saved path.
    private(set) var missingFiles: Set<URL> = []
    /// Subfolders of the lists folder, one level down.
    private(set) var subfolders: [FolderGroup] = []
    /// Folders outside the lists folder (e.g. in Dropbox), shown with their
    /// lists, which are edited in place. Persisted as paths.
    private(set) var linkedFolders: [FolderGroup] = []
    /// Sidebar folder groups the user has folded away.
    var collapsedFolders: Set<URL> = []
    /// `#` titles read from list files that have one.
    private(set) var titles: [URL: String] = [:]
    /// Lists with nothing left to do; earlier repeating copies like these
    /// are tucked away in the sidebar.
    private(set) var finishedLists: Set<URL> = []
    /// Sidebar disclosure state for repeating checklists: templates folded
    /// away, and templates whose finished earlier copies are shown.
    var collapsedTemplates: Set<URL> = []
    var expandedEarlier: Set<URL> = []
    /// Each visible sidebar row's frame in window coordinates, so a task
    /// can be dragged onto it. Not observed: it changes on every layout.
    @ObservationIgnored var sidebarFrames: [URL: CGRect] = [:]
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
    @ObservationIgnored private var watchedFolders: [URL] = []
    @ObservationIgnored private var linkedFolderURLs: [URL] = []
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var titlesTask: Task<Void, Never>?
    @ObservationIgnored private var dayObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var isMakingCopies = false
    @ObservationIgnored private var needsCopiesAgain = false
    @ObservationIgnored private var copiesWait: Task<Void, Never>?
    /// Repeating copies as this Mac made them, for merging versions.
    @ObservationIgnored private var madeCopies = MadeCopies.load()

    init() {
        let folder = UserDefaults.standard.url(forKey: Keys.folder) ?? Self.defaultFolderURL
        folderURL = folder
        library = TaskLibrary(folderURL: folder)
        templateLibrary = TaskLibrary(folderURL: library.templatesFolderURL)
        linkedFiles = (UserDefaults.standard.stringArray(forKey: Keys.linkedFiles) ?? [])
            .map { URL(filePath: $0) }
        linkedFolderURLs = (UserDefaults.standard.stringArray(forKey: Keys.linkedFolders) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
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
                // After this handler: it may show an alert.
                DispatchQueue.main.async { self?.checkICloudFolder() }
                self?.refreshLists()
                self?.document?.checkDisk()
                self?.copiesWait?.cancel()
                self?.makeDueCopies()
            }
        }
        // A new day or a wake from sleep can start a repeating checklist's
        // next period while the app is already in front. Copies are made
        // then only if someone is using this Mac: with Listful running on
        // several Macs sharing the folder through iCloud, the idle ones
        // would each make the same copy before the first one's had synced.
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.makeDueCopiesWhenInUse() }
        }
        // After a wake, iCloud needs a moment to bring in copies made
        // elsewhere while this Mac slept.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.makeDueCopiesWhenInUse(after: .seconds(45)) }
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
        switchFolder(to: url, restoring: nil)
    }

    private func switchFolder(to url: URL, restoring selectedName: String?) {
        closeDocument()
        folderURL = url
        library = TaskLibrary(folderURL: url)
        templateLibrary = TaskLibrary(folderURL: library.templatesFolderURL)
        UserDefaults.standard.set(url, forKey: Keys.folder)
        loadFolder(restoring: selectedName)
    }

    // MARK: - iCloud Drive › Listful

    /// True when the lists folder is iCloud Drive › Listful.
    var isUsingICloudFolder: Bool {
        Self.samePath(folderURL, ListsMigration.iCloudFolderURL())
    }

    /// iCloud Drive › Listful is on this Mac (the iPhone or iPad app has
    /// made it) and the lists are somewhere else.
    var canMoveToICloud: Bool {
        !isUsingICloudFolder && ListsMigration.iCloudContainerExists(at: ListsMigration.iCloudFolderURL())
    }

    @ObservationIgnored private var hasAskedAboutICloud = false

    /// At launch and on activation: if the lists are still in the old
    /// default folder and iCloud Drive › Listful has arrived on this Mac,
    /// move them there (asking first, once per run) or, when another Mac
    /// has already moved them, just switch. A folder the user chose is
    /// left alone; Settings offers the move for that.
    func checkICloudFolder() {
        guard Self.samePath(folderURL, Self.defaultFolderURL) else { return }
        let iCloudFolder = ListsMigration.iCloudFolderURL()
        switch ListsMigration.plan(from: folderURL, to: iCloudFolder) {
        case .none:
            return
        case .switchOnly:
            // The old folder is empty (another Mac moved the lists, or this
            // launch just made it); trash it so it doesn't linger in iCloud.
            let old = folderURL
            try? FileManager.default.createDirectory(at: iCloudFolder, withIntermediateDirectories: true)
            switchFolder(to: iCloudFolder, restoring: savedSelectionName)
            try? ListsMigration.coordinatedTrash(old)
        case .move:
            guard !hasAskedAboutICloud, !UserDefaults.standard.bool(forKey: Keys.declinedICloudMove) else { return }
            hasAskedAboutICloud = true
            offerMoveToICloud(fromLaunch: true)
        }
    }

    /// Asks, then moves everything in the lists folder to iCloud Drive ›
    /// Listful and uses that.
    func offerMoveToICloud(fromLaunch: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Move your task lists to iCloud Drive?"
        alert.informativeText = """
            Listful now keeps task lists in its own folder, iCloud Drive › Listful, which the iPhone \
            and iPad app use too. The lists in “\(folderURL.lastPathComponent)” move there, with their \
            folders and repeating checklists.

            Do this on one Mac: your other Macs switch over by themselves once they have Listful 0.6.
            """
        alert.addButton(withTitle: "Move Lists")
        alert.addButton(withTitle: "Not Now")
        if fromLaunch { alert.addButton(withTitle: "Keep Using “\(folderURL.lastPathComponent)”") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            moveToICloud()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: Keys.declinedICloudMove)
        default:
            break
        }
    }

    private func moveToICloud() {
        let iCloudFolder = ListsMigration.iCloudFolderURL()
        let selectedName = savedSelectionName
        closeDocument()
        do {
            let renamed = try ListsMigration.move(from: folderURL, to: iCloudFolder)
            switchFolder(to: iCloudFolder, restoring: selectedName)
            if !renamed.isEmpty {
                errorMessage = "iCloud Drive › Listful already had lists with the same names as some of yours, "
                    + "so yours were renamed: "
                    + renamed.map { "“\($0.0)” is now “\($0.1)”" }.joined(separator: ", ") + "."
            }
        } catch {
            // Partly moved, perhaps: show what's left where it was.
            loadFolder(restoring: selectedName)
            errorMessage = "Couldn't move all of your task lists to iCloud Drive: \(error.localizedDescription) "
                + "Whatever moved is in iCloud Drive › Listful; the rest is still in “\(folderURL.lastPathComponent)”."
        }
    }

    /// The selected list as saved: relative to the lists folder if inside it.
    private var savedSelectionName: String? {
        UserDefaults.standard.string(forKey: Keys.selectedList)
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        func normal(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return normal(a) == normal(b)
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
        // A linked folder that's now the lists folder or inside it is shown there instead.
        setLinkedFolders(linkedFolderURLs)
        refreshLists()
        // The saved selection is a path relative to the folder for lists inside it, else a full path.
        let restored = selectedName.map { $0.hasPrefix("/") ? URL(filePath: $0) : folderURL.appending(path: $0) }
        selection = allLists.first { $0.path == restored?.path } ?? lists.first
        makeDueCopies()
    }

    /// Every list in the sidebar: the folder's, templates, those in folder
    /// groups, and linked files.
    var allLists: [URL] {
        lists + templates + (subfolders + linkedFolders).flatMap(\.lists) + linkedFiles
    }

    /// The folders whose lists are shown, each as the `TaskLibrary` its
    /// lists' URLs come from.
    private var libraries: [TaskLibrary] {
        [library, templateLibrary] + (subfolders + linkedFolders).map(\.library)
    }

    /// Re-reads the folder and re-checks linked files, keeping the selection
    /// if its file still exists.
    func refreshLists() {
        let current = (try? library.lists()) ?? []
        if current != lists { lists = current }
        let currentTemplates = (try? templateLibrary.lists()) ?? []
        if currentTemplates != templates { templates = currentTemplates }
        let currentSubfolders = ((try? library.subfolders()) ?? []).map { url in
            FolderGroup(url: url, lists: (try? TaskLibrary(folderURL: url).lists()) ?? [], isLinked: false)
        }
        if currentSubfolders != subfolders { subfolders = currentSubfolders }
        let currentLinkedFolders = linkedFolderURLs.map { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            return FolderGroup(url: url, lists: exists ? (try? TaskLibrary(folderURL: url).lists()) ?? [] : [],
                               isLinked: true, isMissing: !exists)
        }
        if currentLinkedFolders != linkedFolders { linkedFolders = currentLinkedFolders }
        let missing = Set(linkedFiles.filter { !TaskLibrary.fileExists($0) })
        if missing != missingFiles { missingFiles = missing }
        watchFolders()
        refreshTitles()

        guard let selection else { return }
        if missing.contains(selection) {
            // Keep it selected so the detail pane can say what happened, but
            // don't save: that would recreate the file where it used to be.
            if document != nil { dropDocument(saving: false) }
        } else if !allLists.contains(selection) {
            // Saving won't recreate it; unsaved edits are kept in a copy.
            dropDocument(saving: true)
            self.selection = nil
        } else if document == nil {
            // A missing linked file has come back.
            openSelection()
        }
    }

    /// Refreshes the sidebar when files are added, removed or renamed by
    /// anything, including Finder, in the folder, its Templates and other
    /// subfolders, or a linked folder. Re-watches only when that set changes.
    private func watchFolders() {
        let folders = [folderURL, templateLibrary.folderURL]
            + (subfolders + linkedFolders).filter { !$0.isMissing }.map(\.url)
        guard folders != watchedFolders else { return }
        watchedFolders = folders
        folderWatchers.forEach { $0.cancel() }
        folderWatchers = folders.compactMap { url in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshLists()
                    // iCloud may have brought in another device's version of a copy.
                    self?.syncCopies(making: false)
                }
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
        let urls = allLists.filter { !missingFiles.contains($0) }
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
            guard let text = try? MarkdownFileStore(fileURL: url).readText() else { continue }
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
        let label = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        // A second copy of the same period, as iCloud names it.
        if let (_, duplicate) = RepeatingChecklists.copyKey(of: url, template: TaskLibrary.displayName(of: template)),
           duplicate > 0 {
            return "\(label) (\(duplicate))"
        }
        return label
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
        document?.clashMerge = RepeatingChecklists.clashMerge(
            for: selection, templates: templateLibrary, lists: library,
            base: madeCopies.texts[TaskLibrary.displayName(of: selection)])
        document?.sidebarTargets = { [weak self] in
            guard let self else { return [:] }
            return sidebarFrames.filter { !missingFiles.contains($0.key) }
        }
        let folderPath = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        let saved = selection.path.hasPrefix(folderPath) ? String(selection.path.dropFirst(folderPath.count)) : selection.path
        UserDefaults.standard.set(saved, forKey: Keys.selectedList)
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
        var linkedAFolder = false
        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                linkFolder(url)
                linkedAFolder = true
                continue
            }
            let url = url.standardizedFileURL
            guard Self.linkableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let owner = libraries.first(where: { $0.contains(url) }) {
                toSelect = owner.canonicalURL(for: url)
                continue
            }
            if !added.contains(url) { added.append(url) }
            toSelect = url
        }
        setLinkedFiles(added)
        refreshLists()
        if let toSelect { selection = toSelect }
        return toSelect != nil || linkedAFolder
    }

    func addExistingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose a folder of task lists to show in the sidebar, such as one in Dropbox or OneDrive. "
            + "Its lists stay where they are and are edited in place."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        linkFolder(url)
    }

    /// Shows a folder from elsewhere in the sidebar. The lists folder, its
    /// subfolders and folders already linked are just expanded.
    func linkFolder(_ url: URL) {
        let url = URL(filePath: url.standardizedFileURL.path, directoryHint: .isDirectory)
        let real = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path }
        let mainFolder = real(folderURL)
        if real(url) == mainFolder { return }
        if let shown = (subfolders + linkedFolders).first(where: { real($0.url) == real(url) }) {
            collapsedFolders.remove(shown.url)
            return
        }
        if real(url.deletingLastPathComponent()) == mainFolder {
            return  // A subfolder, already shown (Templates is shown as Repeating).
        }
        setLinkedFolders(linkedFolderURLs + [url])
        refreshLists()
        collapsedFolders.remove(url)
    }

    func isLinkedFolder(_ url: URL) -> Bool {
        linkedFolderURLs.contains(url)
    }

    /// Removes a linked folder from the sidebar. The folder is untouched.
    func unlinkFolder(_ url: URL) {
        let wasInside = selection.map { $0.deletingLastPathComponent().path == url.path } ?? false
        if wasInside { closeDocument() }
        setLinkedFolders(linkedFolderURLs.filter { $0 != url })
        refreshLists()
        if wasInside { selection = lists.first }
    }

    private func setLinkedFolders(_ urls: [URL]) {
        let real = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path }
        let mainFolder = real(folderURL)
        var seen = Set<String>()
        let kept = urls.filter { url in
            let path = real(url)
            return path != mainFolder && real(url.deletingLastPathComponent()) != mainFolder && seen.insert(path).inserted
        }
        let sorted = kept.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        linkedFolderURLs = sorted
        UserDefaults.standard.set(sorted.map(\.path), forKey: Keys.linkedFolders)
        // A linked file that's in a shown folder is listed there instead.
        let shown = Set([mainFolder] + sorted.map(real))
        setLinkedFiles(linkedFiles.filter { !shown.contains(real($0.deletingLastPathComponent())) })
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

    /// Asks for a new list's name. It goes in `folder` if given, else in the
    /// folder group the open list is in, else the lists folder.
    func promptNewList(in folder: URL? = nil) {
        let target = folder ?? selection.flatMap(folderGroup(containing:))?.url ?? folderURL
        nameDraft = TaskLibrary(folderURL: target).suggestedNewName()
        namePrompt = .newList(target)
    }

    func promptNewFolder() {
        nameDraft = library.suggestedNewName(base: "New Folder")
        namePrompt = .newFolder
    }

    func promptRename(_ url: URL) {
        nameDraft = url.hasDirectoryPath ? url.lastPathComponent : displayName(of: url)
        namePrompt = .rename(url)
    }

    /// The subfolder or linked folder whose lists include `url`.
    func folderGroup(containing url: URL) -> FolderGroup? {
        (subfolders + linkedFolders).first { $0.lists.contains(url) }
    }

    /// The name of a folder new lists can go in, for prompts; nil for the lists folder.
    func folderName(_ url: URL) -> String? {
        url.path == folderURL.path || url.path == folderURL.path + "/" ? nil : url.lastPathComponent
    }

    func commitNamePrompt(_ prompt: NamePrompt) {
        namePrompt = nil
        do {
            switch prompt {
            case .newList(let folder):
                let owner = libraries.first { $0.folderURL.path == folder.path } ?? TaskLibrary(folderURL: folder)
                let url = try owner.createList(named: nameDraft)
                collapsedFolders.remove(folder)
                refreshLists()
                selection = url
                document?.focusFirstRow()
            case .newFolder:
                let url = try library.createFolder(named: nameDraft)
                refreshLists()
                collapsedFolders.remove(url)
            case .rename(let url) where url.hasDirectoryPath:
                let selectedName = selection.flatMap { $0.deletingLastPathComponent().path == url.path ? $0.lastPathComponent : nil }
                if selectedName != nil { closeDocument() }
                let renamed = try library.renameFolder(at: url, to: nameDraft)
                if collapsedFolders.remove(url) != nil { collapsedFolders.insert(renamed) }
                refreshLists()
                if let selectedName {
                    selection = nil
                    selection = subfolders.first { $0.url == renamed }?.lists.first { $0.lastPathComponent == selectedName }
                }
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
        if url.hasDirectoryPath {
            trashFolder(url)
            return
        }
        let wasSelected = selection == url
        let neighbour = wasSelected ? neighbourInList(of: url) : nil
        if wasSelected { closeDocument() }
        do {
            try owner(of: url).trashList(at: url)
        } catch {
            errorMessage = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
        }
        refreshLists()
        if wasSelected { selection = neighbour.flatMap { allLists.contains($0) ? $0 : nil } ?? lists.first }
    }

    private func trashFolder(_ url: URL) {
        let wasInside = selection.map { $0.deletingLastPathComponent().path == url.path } ?? false
        if wasInside { closeDocument() }
        do {
            try library.trashFolder(at: url)
        } catch {
            errorMessage = "Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)"
        }
        refreshLists()
        if wasInside { selection = lists.first }
    }

    private func neighbourInList(of url: URL) -> URL? {
        let siblings = templates.contains(url) ? templates : folderGroup(containing: url)?.lists ?? lists
        guard let i = siblings.firstIndex(of: url) else { return nil }
        if i + 1 < siblings.count { return siblings[i + 1] }
        return i > 0 ? siblings[i - 1] : nil
    }

    /// The folder a list belongs to, as the `TaskLibrary` its URL came from.
    private func owner(of url: URL) -> TaskLibrary {
        if templates.contains(url) { return templateLibrary }
        return folderGroup(containing: url)?.library ?? library
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
            watchedFolders = []  // Templates may be new, so watch it afresh.
            refreshLists()
            selection = url
            document?.focusFirstRow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Makes the copies that are due once this Mac is in use: after `delay`,
    /// as soon as there's been keyboard or mouse input in the last minute.
    private func makeDueCopiesWhenInUse(after delay: Duration = .zero) {
        copiesWait?.cancel()
        copiesWait = Task {
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                if Self.secondsSinceInput < 60 {
                    makeDueCopies()
                    return
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private static var secondsSinceInput: Double {
        // ~0 is kCGAnyInputEventType.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Makes any repeating checklist copies that are due, off the main
    /// thread, and merges away duplicate copies. If the open list was the previous copy, the new one is opened
    /// in its place. Overlapping requests run once more afterwards.
    func makeDueCopies() {
        syncCopies(making: true)
    }

    /// Settles versions of copies made or changed on two devices at once
    /// (see `RepeatingChecklists.syncCopies`), and with `making`, first
    /// makes the copies that are due, if this Mac makes them.
    private func syncCopies(making: Bool) {
        guard !isMakingCopies else {
            if making { needsCopiesAgain = true }
            return
        }
        isMakingCopies = true
        // Save first, so tasks being carried over include the latest edits.
        if making { document?.saveNow() }
        let templates = templateLibrary, lists = library, open = selection
        let bases = madeCopies.texts, device = RepeatingDevice.thisMac.id
        Task {
            let result = await Task.detached {
                if making {
                    return RepeatingChecklists.syncCopies(
                        templates: templates, lists: lists, keeping: open, bases: bases, deviceID: device,
                        date: Date(), calendar: .current, locale: .current)
                }
                var result = RepeatingChecklists.SyncResult()
                result.conflicts = RepeatingChecklists.resolveConflicts(
                    templates: templates, lists: lists, date: Date(), calendar: .current, bases: bases)
                return result
            }.value
            isMakingCopies = false
            for made in result.made {
                if let copy = made.copy, let text = made.madeText {
                    madeCopies.record(text, name: TaskLibrary.displayName(of: copy), made: Date())
                }
            }
            if result.made.contains(where: { $0.madeText != nil }) { madeCopies.save() }
            if result.changedLists { refreshLists() }
            if result.conflicts.merged.contains(where: { $0 == document?.fileURL }) { document?.checkDisk() }
            if let error = result.made.compactMap(\.error).first { errorMessage = error }
            if let conflict = result.conflicts.copies.first {
                errorMessage = "“\(TaskLibrary.displayName(of: conflict.list))” was changed on two devices while they were "
                    + "out of touch. The other version is saved beside it as “\(TaskLibrary.displayName(of: conflict.copy))”."
            }
            if let moved = result.made.first(where: { $0.copy != nil && $0.previous != nil && $0.previous == selection }) {
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
