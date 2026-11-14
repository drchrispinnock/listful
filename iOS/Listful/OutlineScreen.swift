import SwiftUI
import ListfulCore

/// One list as an editable outline. Tap a bullet to tick a task; Return
/// splits a row; the bar above the keyboard indents, outdents and moves the
/// row being edited; long-press and drag to move a task and its subtasks.
struct OutlineScreen: View {
    @Bindable var document: ListDocument
    @Bindable var library: LibraryStore
    @FocusState private var focus: UUID?
    @FocusState private var isTitleFocused: Bool
    @AppStorage("deleteDecruftedTasks") private var deleteDecrufted = false

    var body: some View {
        content
            .navigationTitle(document.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert(
                "Task list",
                isPresented: Binding(
                    get: { document.errorMessage != nil },
                    set: { if !$0 { document.errorMessage = nil } }),
                presenting: document.errorMessage
            ) { _ in
                Button("OK") {}
            } message: { Text($0) }
    }

    @ViewBuilder private var content: some View {
        switch document.loadState {
        case .downloading:
            ContentUnavailableView(
                "Downloading from iCloud…", systemImage: "icloud.and.arrow.down",
                description: Text("“\(document.fileName)” will open once it's on this device."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Open Task List", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { document.reload() }
            }
        case .loaded:
            outline
        }
    }

    private var outline: some View {
        let rows = document.visibleItems(showDecrufted: library.showDecrufted)
        return List {
            if document.outline.title != nil {
                TextField("Title", text: Binding(
                    get: { document.outline.title ?? "" },
                    set: { document.setListTitle($0) }))
                    .font(.title.bold())
                    .focused($isTitleFocused)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }
            ForEach(rows) { item in
                RowView(item: item, document: document, focus: $focus)
                    .moveDisabled(item.isHeading)
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                document.moveVisibleRow(from: from, to: destination, showDecrufted: library.showDecrufted)
            }
            Button {
                document.appendTask()
            } label: {
                Label("New Task", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
            .moveDisabled(true)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 34)
        .onChange(of: document.focusRequest) { _, id in
            guard let id else { return }
            // Let the new row's field appear first.
            DispatchQueue.main.async {
                focus = id
                document.focusRequest = nil
            }
        }
        .onChange(of: focus) { _, id in
            if let id { document.focusedID = id }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Sort A–Z", systemImage: "arrow.up.arrow.down") { document.sort(focus) }
                Button("Decruft Done Tasks", systemImage: "eye.slash") { document.decruft(deleting: deleteDecrufted) }
                Toggle(isOn: $library.showDecrufted) { Label("Show Decrufted Tasks", systemImage: "eye") }
                Divider()
                Button("Reload", systemImage: "arrow.clockwise") { document.reload() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            if let id = focus {
                Button { document.outdent(id); refocus(id) } label: { Label("Outdent", systemImage: "decrease.indent") }
                Button { document.indent(id); refocus(id) } label: { Label("Indent", systemImage: "increase.indent") }
                Button { document.moveUp(id); refocus(id) } label: { Label("Move Up", systemImage: "arrow.up") }
                Button { document.moveDown(id); refocus(id) } label: { Label("Move Down", systemImage: "arrow.down") }
                Button { document.toggleDone(id) } label: { Label("Done", systemImage: "checkmark.circle") }
            }
            Spacer()
            Button {
                focus = nil
                isTitleFocused = false
            } label: {
                Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
            }
        }
    }

    /// Structural moves can make the List re-create the row's field, which
    /// drops focus; ask for it back.
    private func refocus(_ id: UUID) {
        document.focusRequest = id
    }
}

/// One row: indentation, a disclosure chevron for collapsible rows, a tick
/// box (tasks) and the editable text.
struct RowView: View {
    let item: TaskItem
    let document: ListDocument
    var focus: FocusState<UUID?>.Binding
    @AppStorage("showCompletionTick") private var showTick = true
    @AppStorage("showCompletionStrikethrough") private var showStrikethrough = true

    private static let indentWidth: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Color.clear.frame(width: CGFloat(item.depth) * Self.indentWidth, height: 1)
            chevron
            if item.isHeading {
                field
                    .font(headingFont)
                    .fontWeight(.semibold)
            } else {
                Button { document.toggleDone(item.id) } label: {
                    Image(systemName: symbol)
                        .imageScale(showTick ? .large : .small)
                        .foregroundStyle(showTick && item.state != .open ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.state == .open ? "Mark done" : "Mark open")
                field
                    .strikethrough(showStrikethrough && item.state != .open)
                    .foregroundStyle(item.state == .open ? .primary : .secondary)
            }
        }
        .padding(.top, item.isHeading ? 8 : 0)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading) {
            if !item.isHeading {
                Button(item.state == .open ? "Done" : "Open", systemImage: "checkmark") { document.toggleDone(item.id) }
                    .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { document.delete(item.id) }
        }
        .contextMenu {
            if item.isHeading {
                Button("Make Task", systemImage: "circle") { document.makeTask(item.id) }
            } else {
                Button("Heading 1") { document.makeHeading(1, for: item.id) }
                Button("Heading 2") { document.makeHeading(2, for: item.id) }
                Button("Heading 3") { document.makeHeading(3, for: item.id) }
            }
            Button("Sort A–Z", systemImage: "arrow.up.arrow.down") { document.sort(item.id) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { document.delete(item.id) }
        }
    }

    private var field: some View {
        TextField(item.isHeading ? "Heading" : "", text: Binding(
            get: { item.title },
            set: { document.setTitle($0, for: item.id) }
        ), axis: .vertical)
        .focused(focus, equals: item.id)
    }

    @ViewBuilder private var chevron: some View {
        if document.canCollapse(item.id) {
            Button { document.toggleCollapsed(item.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(item.isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
            .accessibilityLabel(item.isCollapsed ? "Expand" : "Collapse")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private var headingFont: Font {
        switch item.headingLevel {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }

    private var symbol: String {
        let isCollapsedParent = item.isCollapsed && document.canCollapse(item.id)
        guard showTick else { return isCollapsedParent ? "smallcircle.filled.circle" : "circle.fill" }
        switch item.state {
        case .open: return isCollapsedParent ? "circle.circle" : "circle"
        case .done, .decrufted: return "checkmark.circle.fill"
        }
    }
}
