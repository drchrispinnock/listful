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
            if let document = library.document {
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
        List(selection: $library.selection) {
            Section(library.folderURL.lastPathComponent) {
                ForEach(library.ungroupedLists, id: \.self) { url in
                    Label(library.displayName(of: url), systemImage: "checklist")
                        .tag(url)
                }
            }
            if !library.templates.isEmpty {
                Section("Repeating") {
                    ForEach(library.templates, id: \.self) { template in
                        RepeatingGroup(library: library, template: template)
                    }
                }
            }
            if !library.linkedFiles.isEmpty {
                Section("Other Files") {
                    ForEach(library.linkedFiles, id: \.self) { url in
                        LinkedFileRow(url: url, name: library.displayName(of: url), isMissing: library.missingFiles.contains(url))
                            .tag(url)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
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
            } else {
                Button("New Task List…") { library.promptNewList() }
                Button("New Repeating Checklist…") { library.promptNewRepeating() }
                Button("Add Existing File…") { library.addExistingFiles() }
            }
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
                    Button("New Task List…") { library.promptNewList() }
                    Button("New Repeating Checklist…") { library.promptNewRepeating() }
                    Button("Add Existing File…") { library.addExistingFiles() }
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
            Button(prompt == .newList ? "Create" : "Rename") { library.commitNamePrompt(prompt) }
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
        } message: { _ in
            Text("You can restore it from the Trash in Finder.")
        }
    }

    private var trashTitle: String {
        library.pendingTrash.map { "Move “\(library.displayName(of: $0))” to the Trash?" } ?? ""
    }

    private var namePromptTitle: String {
        switch library.namePrompt {
        case .rename(let url) where library.templates.contains(url): "Rename Repeating Checklist"
        case .rename: "Rename Task List"
        case .newList, nil: "New Task List"
        }
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
                    .tag(copy)
            }
            if !groups.earlier.isEmpty {
                DisclosureGroup(isExpanded: expansion(of: $library.expandedEarlier, inverted: false)) {
                    ForEach(groups.earlier, id: \.self) { copy in
                        Label(library.copyLabel(of: copy, template: template), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .tag(copy)
                    }
                } label: {
                    Text("Earlier (\(groups.earlier.count))")
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(library.displayName(of: template), systemImage: "repeat")
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
