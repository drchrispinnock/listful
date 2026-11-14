import SwiftUI
import ListfulCore

/// The main window: a hideable sidebar of task lists beside the open list.
struct ContentView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            if let document = library.document, document.loadState == .downloading {
                ContentUnavailableView {
                    Label("Downloading from iCloud…", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text("“\(document.fileName)” will open once it's on this Mac.")
                }
            } else if let document = library.document, case .failed(let message) = document.loadState {
                ContentUnavailableView {
                    Label("Can't Open Task List", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { document.reload() }
                }
            } else if let document = library.document {
                OutlineView(document: document)
                    // Fresh row views per list, so no text field state leaks between lists.
                    .id(ObjectIdentifier(document))
            } else if let missing = library.selection, library.missingFiles.contains(missing) {
                ContentUnavailableView {
                    Label("File Not Found", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("\(missing.path(percentEncoded: false)) has been moved or deleted.")
                } actions: {
                    Button("Locate…") { library.relocate(missing) }
                    Button("Remove from Sidebar") { library.unlink(missing) }
                }
            } else {
                ContentUnavailableView {
                    Label("No Task List", systemImage: "checklist")
                } description: {
                    Text(library.lists.isEmpty ? "Create a task list to get started." : "Select a task list in the sidebar.")
                } actions: {
                    Button("New Task List") { library.promptNewList() }
                    Button("Add Existing File…") { library.addExistingFiles() }
                }
            }
        }
        .sheet(isPresented: $library.isCreatingRepeating) { NewRepeatingSheet(library: library) }
        .alert(
            "Task lists",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            ),
            presenting: library.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

struct SidebarView: View {
    @Bindable var library: LibraryModel

    var body: some View {
        List(selection: selection) {
            Section(library.folderURL.lastPathComponent) {
                ForEach(library.ungroupedLists, id: \.self) { url in
                    Label(library.displayName(of: url), systemImage: "checklist")
                        .sidebarDropTarget(url, library: library)
                        .tag(url)
                }
                ForEach(library.subfolders, id: \.url) { group in
                    FolderGroupView(library: library, group: group)
                }
            }
            if !library.templates.isEmpty {
                Section("Repeating") {
                    ForEach(library.templates, id: \.self) { template in
                        RepeatingGroup(library: library, template: template)
                    }
                }
            }
            if !library.linkedFolders.isEmpty {
                Section("Other Folders") {
                    ForEach(library.linkedFolders, id: \.url) { group in
                        FolderGroupView(library: library, group: group)
                    }
                }
            }
            if !library.linkedFiles.isEmpty {
                Section("Other Files") {
                    ForEach(library.linkedFiles, id: \.self) { url in
                        LinkedFileRow(url: url, name: library.displayName(of: url), isMissing: library.missingFiles.contains(url))
                            .sidebarDropTarget(url, library: library)
                            .tag(url)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            contextMenu(for: urls.first)
        }
        .onDeleteCommand {
            // Delete never touches a linked file; it only leaves the sidebar.
            guard let selection = library.selection else { return }
            if library.isLinked(selection) { library.unlink(selection) } else { library.confirmTrash(selection) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.link(urls)
        }
        // A bar at the foot of the sidebar rather than a toolbar item: a
        // sidebar toolbar item ends up in the overflow menu or vanishes
        // depending on the detail column's toolbar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Menu {
                    addItems
                } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.iconOnly)
                } primaryAction: {
                    library.promptNewList()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New task list (hold for more options)")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .alert(
            namePromptTitle,
            isPresented: Binding(
                get: { library.namePrompt != nil },
                set: { if !$0 { library.namePrompt = nil } }
            ),
            presenting: library.namePrompt
        ) { prompt in
            TextField("Name", text: $library.nameDraft)
            Button(isRename(prompt) ? "Rename" : "Create") { library.commitNamePrompt(prompt) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            trashTitle,
            isPresented: Binding(
                get: { library.pendingTrash != nil },
                set: { if !$0 { library.pendingTrash = nil } }
            ),
            presenting: library.pendingTrash
        ) { url in
            Button("Move to Trash", role: .destructive) { library.trash(url) }
            // Cancel is the default, so Return doesn't confirm by accident.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { url in
            if url.hasDirectoryPath {
                Text("Every task list in the folder goes too. You can restore it from the Trash in Finder.")
            } else {
                Text("You can restore it from the Trash in Finder.")
            }
        }
    }

    /// Clicking a folder's row folds or unfolds it rather than selecting it,
    /// since only lists can be open.
    private var selection: Binding<URL?> {
        Binding(
            get: { library.selection },
            set: { url in
                if let url, url.hasDirectoryPath {
                    if library.collapsedFolders.remove(url) == nil { library.collapsedFolders.insert(url) }
                } else {
                    library.selection = url
                }
            })
    }

    @ViewBuilder private var addItems: some View {
        Button("New Task List…") { library.promptNewList() }
        Button("New Repeating Checklist…") { library.promptNewRepeating() }
        Button("New Folder…") { library.promptNewFolder() }
        Divider()
        Button("Add Existing File…") { library.addExistingFiles() }
        Button("Add Existing Folder…") { library.addExistingFolder() }
    }

    @ViewBuilder private func contextMenu(for url: URL?) -> some View {
        if let url, url.hasDirectoryPath {
            folderMenu(url)
        } else if let url {
            listMenu(url)
        } else {
            addItems
        }
    }

    @ViewBuilder private func listMenu(_ url: URL) -> some View {
        if library.isLinked(url) {
            Button("Show in Finder") { library.revealInFinder(url) }
                .disabled(library.missingFiles.contains(url))
            Divider()
            Button("Remove from Sidebar") { library.unlink(url) }
        } else {
            Button("Rename…") { library.promptRename(url) }
            Button("Show in Finder") { library.revealInFinder(url) }
            Divider()
            Button("Move to Trash…") { library.confirmTrash(url) }
        }
    }

    @ViewBuilder private func folderMenu(_ url: URL) -> some View {
        let isLinked = library.isLinkedFolder(url)
        let isMissing = library.linkedFolders.contains { $0.url == url && $0.isMissing }
        Button("New Task List in Folder…") { library.promptNewList(in: url) }
            .disabled(isMissing)
        if !isLinked { Button("Rename…") { library.promptRename(url) } }
        Button("Show in Finder") { library.revealInFinder(url) }
            .disabled(isMissing)
        Divider()
        if isLinked {
            Button("Remove from Sidebar") { library.unlinkFolder(url) }
        } else {
            Button("Move to Trash…") { library.confirmTrash(url) }
        }
    }

    private func isRename(_ prompt: LibraryModel.NamePrompt) -> Bool {
        if case .rename = prompt { true } else { false }
    }

    private var trashTitle: String {
        guard let url = library.pendingTrash else { return "" }
        if url.hasDirectoryPath { return "Move the folder “\(url.lastPathComponent)” to the Trash?" }
        return "Move “\(library.displayName(of: url))” to the Trash?"
    }

    private var namePromptTitle: String {
        switch library.namePrompt {
        case .rename(let url) where library.templates.contains(url): "Rename Repeating Checklist"
        case .rename(let url) where url.hasDirectoryPath: "Rename Folder"
        case .rename: "Rename Task List"
        case .newFolder: "New Folder"
        case .newList(let folder):
            library.folderName(folder).map { "New Task List in “\($0)”" } ?? "New Task List"
        case nil: "New Task List"
        }
    }
}

extension View {
    /// Makes a sidebar row somewhere a task can be dragged to: reports its
    /// frame, and is highlighted while a task is over it.
    func sidebarDropTarget(_ url: URL, library: LibraryModel) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                library.sidebarFrames[url] = $0
            }
            .onDisappear { library.sidebarFrames[url] = nil }
            .overlay {
                if library.document?.drag?.targetList == url {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                }
            }
    }
}

/// A subfolder or linked folder in the sidebar, with its lists beneath it.
/// Its row is tagged with the folder's URL (trailing slash) for the context
/// menu; selecting it just folds or unfolds it.
struct FolderGroupView: View {
    @Bindable var library: LibraryModel
    let group: LibraryModel.FolderGroup

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(group.lists, id: \.self) { url in
                Label(library.displayName(of: url), systemImage: "checklist")
                    .sidebarDropTarget(url, library: library)
                    .tag(url)
            }
            if group.lists.isEmpty {
                Text(group.isMissing ? "Not found" : "No task lists")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        } label: {
            Label {
                if group.isLinked {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                        Text(group.isMissing ? "Not found" : location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(group.name)
                }
            } icon: {
                Image(systemName: group.isMissing ? "questionmark.folder" : "folder")
            }
            .tag(group.url)
            .help(group.url.path(percentEncoded: false))
        }
    }

    private var location: String {
        let parent = group.url.deletingLastPathComponent().path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return parent.hasPrefix(home) ? "~/" + parent.dropFirst(home.count) : parent
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { !library.collapsedFolders.contains(group.url) },
            set: { expanded in
                if expanded { library.collapsedFolders.remove(group.url) } else { library.collapsedFolders.insert(group.url) }
            })
    }
}

/// A template in the sidebar with its copies beneath it: the newest, earlier
/// ones with tasks left, and the finished ones folded into "Earlier".
struct RepeatingGroup: View {
    @Bindable var library: LibraryModel
    let template: URL

    var body: some View {
        let groups = library.copyGroups(of: template)
        DisclosureGroup(isExpanded: expansion(of: $library.collapsedTemplates, inverted: true)) {
            ForEach(groups.shown, id: \.self) { copy in
                Label(library.copyLabel(of: copy, template: template), systemImage: "checklist")
                    .sidebarDropTarget(copy, library: library)
                    .tag(copy)
            }
            if !groups.earlier.isEmpty {
                DisclosureGroup(isExpanded: expansion(of: $library.expandedEarlier, inverted: false)) {
                    ForEach(groups.earlier, id: \.self) { copy in
                        Label(library.copyLabel(of: copy, template: template), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .sidebarDropTarget(copy, library: library)
                            .tag(copy)
                    }
                } label: {
                    Text("Earlier (\(groups.earlier.count))")
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(library.displayName(of: template), systemImage: "repeat")
                .sidebarDropTarget(template, library: library)
                .tag(template)
                .help("Template: edit it to change future copies")
        }
    }

    /// Whether this template is in `set`, as a disclosure binding; inverted
    /// for a set of the collapsed ones, so groups start out open.
    private func expansion(of set: Binding<Set<URL>>, inverted: Bool) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(template) != inverted },
            set: { isExpanded in
                if isExpanded != inverted { set.wrappedValue.insert(template) } else { set.wrappedValue.remove(template) }
            })
    }
}

/// A sidebar row for a file outside the task-lists folder: its name, plus
/// where it lives so same-named files (e.g. several TODO.md) can be told apart.
struct LinkedFileRow: View {
    let url: URL
    let name: String
    let isMissing: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(isMissing ? "Not found" : location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        } icon: {
            Image(systemName: isMissing ? "exclamationmark.triangle" : "doc.text")
        }
        .opacity(isMissing ? 0.6 : 1)
        .help(url.path(percentEncoded: false))
    }

    private var location: String {
        (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}
