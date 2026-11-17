import SwiftUI
import UIKit
import ListfulCore

/// One list as an editable outline. Tap a bullet to tick a task; Return
/// starts a new task (splitting the row at the cursor); the bar above the
/// keyboard indents, outdents and moves the row being edited; long-press and
/// drag to move a task and its subtasks.
struct OutlineScreen: View {
    @Bindable var document: ListDocument
    @Bindable var library: LibraryStore
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
                    .onSubmit { document.focusFirstRow() }
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }
            ForEach(rows) { item in
                RowView(item: item, document: document)
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
        .environment(\.defaultMinListRowHeight, 0)
        .safeAreaInset(edge: .bottom) {
            if document.editingID != nil || isTitleFocused { editingBar }
        }
    }

    /// Above the keyboard while a row is being edited.
    private var editingBar: some View {
        HStack(spacing: 4) {
            if let id = document.editingID {
                barButton("Outdent", "decrease.indent") { document.outdent(id); refocus(id) }
                barButton("Indent", "increase.indent") { document.indent(id); refocus(id) }
                barButton("Move Up", "arrow.up") { document.moveUp(id); refocus(id) }
                barButton("Move Down", "arrow.down") { document.moveDown(id); refocus(id) }
                barButton("Done", "checkmark.circle") { document.toggleDone(id) }
            }
            Spacer()
            barButton("Hide Keyboard", "keyboard.chevron.compact.down") {
                isTitleFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func barButton(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Sort A–Z", systemImage: "arrow.up.arrow.down") { document.sort(document.editingID) }
                Button("Decruft Done Tasks", systemImage: "eye.slash") { document.decruft(deleting: deleteDecrufted) }
                Toggle(isOn: $library.showDecrufted) { Label("Show Decrufted Tasks", systemImage: "eye") }
                Divider()
                Button("Reload", systemImage: "arrow.clockwise") { document.reload() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// Structural moves can make the List re-create the row's text view,
    /// which drops focus; ask for it back.
    private func refocus(_ id: UUID) {
        document.focusRequest = id
    }
}

/// One row: indentation, a disclosure chevron for collapsible rows, a tick
/// box (tasks) and the editable text. Done tasks are ticked and greyed, not
/// struck through: strikethrough is hard to read on a phone.
struct RowView: View {
    let item: TaskItem
    let document: ListDocument

    private static let indentWidth: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: CGFloat(item.depth) * Self.indentWidth, height: 1)
            chevron
            if !item.isHeading {
                Button { document.toggleDone(item.id) } label: {
                    Image(systemName: symbol)
                        .imageScale(.large)
                        .foregroundStyle(item.state != .open ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: lineHeight)
                        // A finger-sized target around the small symbol.
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.state == .open ? "Mark done" : "Mark open")
            }
            TaskTextView(
                id: item.id, text: item.title, font: font,
                isDimmed: !item.isHeading && item.state != .open,
                wantsFocus: document.focusRequest == item.id,
                document: document)
        }
        .padding(.top, item.isHeading ? 6 : 0)
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
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

    @ViewBuilder private var chevron: some View {
        if document.canCollapse(item.id) {
            Button { document.toggleCollapsed(item.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(item.isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: lineHeight)
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
            .accessibilityLabel(item.isCollapsed ? "Expand" : "Collapse")
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }

    private var font: UIFont {
        guard item.isHeading else { return .preferredFont(forTextStyle: .body) }
        let style: UIFont.TextStyle = switch item.headingLevel {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
        let base = UIFont.preferredFont(forTextStyle: style)
        return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor, size: 0)
    }

    private var lineHeight: CGFloat { font.lineHeight }

    private var symbol: String {
        let isCollapsedParent = item.isCollapsed && document.canCollapse(item.id)
        switch item.state {
        case .open: return isCollapsedParent ? "circle.circle" : "circle"
        case .done, .decrufted: return "checkmark.circle.fill"
        }
    }
}
