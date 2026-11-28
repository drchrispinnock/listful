import SwiftUI
import ListfulCore

/// The folder's lists, its subfolders, and repeating checklists with their copies.
struct SidebarView: View {
    @Bindable var library: LibraryStore
    @State private var isShowingSettings = false

    var body: some View {
        List(selection: $library.selection) {
            Section(library.isUsingICloudFolder ? "Listful" : library.folderURL?.lastPathComponent ?? "Task Lists") {
                ForEach(library.ungroupedLists, id: \.self) { url in
                    ListRow(library: library, url: url, label: library.displayName(of: url))
                }
                ForEach(library.subfolders, id: \.url) { folder in
                    FolderRow(library: library, folder: folder)
                }
            }
            if !library.templates.isEmpty {
                Section("Repeating") {
                    ForEach(library.templates, id: \.self) { template in
                        RepeatingRows(library: library, template: template)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Listful")
        .refreshable { library.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { isShowingSettings = true } label: { Label("Settings", systemImage: "gear") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { library.promptNewList() } label: { Label("New Task List", systemImage: "checklist") }
                    Button { library.promptNewFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    library.promptNewList()
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) { SettingsView(library: library) }
        .alert(
            namePromptTitle,
            isPresented: Binding(
                get: { library.namePrompt != nil },
                set: { if !$0 { library.namePrompt = nil } }),
            presenting: library.namePrompt
        ) { prompt in
            TextField("Name", text: $library.nameDraft)
            Button(isRename(prompt) ? "Rename" : "Create") { library.commitNamePrompt(prompt) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            trashTitle,
            isPresented: Binding(
                get: { library.pendingTrash != nil },
                set: { if !$0 { library.pendingTrash = nil } }),
            titleVisibility: .visible,
            presenting: library.pendingTrash
        ) { url in
            Button("Move to Trash", role: .destructive) { library.trash(url) }
        } message: { url in
            Text(url.hasDirectoryPath ? "Every task list in the folder goes too." : "You can get it back from Recently Deleted in Files.")
        }
    }

    private var namePromptTitle: String {
        switch library.namePrompt {
        case .rename(let url) where url.hasDirectoryPath: "Rename Folder"
        case .rename: "Rename Task List"
        case .newFolder: "New Folder"
        case .newList(let folder): library.folderName(folder).map { "New Task List in “\($0)”" } ?? "New Task List"
        case nil: ""
        }
    }

    private var trashTitle: String {
        guard let url = library.pendingTrash else { return "" }
        return url.hasDirectoryPath
            ? "Move the folder “\(url.lastPathComponent)” to the Trash?"
            : "Move “\(library.displayName(of: url))” to the Trash?"
    }

    private func isRename(_ prompt: LibraryStore.NamePrompt) -> Bool {
        if case .rename = prompt { true } else { false }
    }
}

/// A list in the sidebar, with Rename and Move to Trash.
struct ListRow: View {
    let library: LibraryStore
    let url: URL
    let label: String
    var systemImage = "checklist"

    var body: some View {
        NavigationLink(value: url) {
            Label(label, systemImage: systemImage)
        }
        .swipeActions {
            Button("Trash", systemImage: "trash", role: .destructive) { library.pendingTrash = url }
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil") { library.promptRename(url) }
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { library.pendingTrash = url }
        }
    }
}

struct FolderRow: View {
    @Bindable var library: LibraryStore
    let folder: LibraryStore.Folder

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !library.collapsedFolders.contains(folder.url) },
            set: { if $0 { library.collapsedFolders.remove(folder.url) } else { library.collapsedFolders.insert(folder.url) } }
        )) {
            ForEach(folder.lists, id: \.self) { url in
                ListRow(library: library, url: url, label: library.displayName(of: url))
            }
            if folder.lists.isEmpty {
                Text("No task lists").foregroundStyle(.secondary)
            }
        } label: {
            Label(folder.name, systemImage: "folder")
                .contextMenu {
                    Button("New Task List in Folder…", systemImage: "plus") { library.promptNewList(in: folder.url) }
                    Button("Rename…", systemImage: "pencil") { library.promptRename(folder.url) }
                    Button("Move to Trash…", systemImage: "trash", role: .destructive) { library.pendingTrash = folder.url }
                }
        }
    }
}

/// A repeating checklist's template, then its copies: the newest, earlier
/// ones with tasks left, and the finished ones under "Earlier".
struct RepeatingRows: View {
    @Bindable var library: LibraryStore
    let template: URL

    var body: some View {
        let groups = library.copyGroups(of: template)
        ListRow(library: library, url: template, label: library.displayName(of: template), systemImage: "repeat")
        ForEach(groups.shown, id: \.self) { copy in
            ListRow(library: library, url: copy, label: library.copyLabel(of: copy, template: template))
                .padding(.leading, 16)
        }
        if !groups.earlier.isEmpty {
            DisclosureGroup("Earlier (\(groups.earlier.count))", isExpanded: Binding(
                get: { library.expandedEarlier.contains(template) },
                set: { if $0 { library.expandedEarlier.insert(template) } else { library.expandedEarlier.remove(template) } }
            )) {
                ForEach(groups.earlier, id: \.self) { copy in
                    ListRow(library: library, url: copy, label: library.copyLabel(of: copy, template: template),
                            systemImage: "checkmark.circle")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
        }
    }
}

struct SettingsView: View {
    let library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Folder", value: library.isUsingICloudFolder
                        ? "iCloud Drive › Listful" : library.folderURL?.lastPathComponent ?? "None")
                    if !library.isUsingICloudFolder {
                        Button("Use iCloud Drive › Listful") {
                            dismiss()
                            library.useICloudFolder()
                        }
                    }
                    Button("Choose Another Folder…") {
                        dismiss()
                        library.isChoosingFolder = true
                    }
                } footer: {
                    Text("iCloud Drive › Listful is the folder the Mac app uses too.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
