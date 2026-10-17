import SwiftUI
import ListfulCore

struct OutlineView: View {
    @Bindable var document: TaskDocument

    var body: some View {
        let rows = document.visibleItems
        ScrollView {
            // Not lazy: every row's text field must exist so focus can move to it.
            VStack(alignment: .leading, spacing: 2) {
                ListTitleField(document: document)
                    .padding(.bottom, 10)
                ForEach(rows) { item in
                    TaskRow(item: item, document: document)
                }
                if rows.isEmpty {
                    Button("New Task") { document.appendTask() }
                        .padding(.top, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(document.displayTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    document.decruft()
                } label: {
                    Label("Decruft", systemImage: "sparkles")
                }
                .help("Hide all done tasks (they're kept in the file)")

                Toggle(isOn: Bindable(document.options).showDecrufted) {
                    Label("Show Decrufted", systemImage: document.options.showDecrufted ? "eye" : "eye.slash")
                }
                .help("Show or hide decrufted tasks")
            }
        }
        .alert(
            "Task file error",
            isPresented: Binding(
                get: { document.errorMessage != nil },
                set: { if !$0 { document.errorMessage = nil } }
            ),
            presenting: document.errorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }
}

struct TaskRow: View {
    let item: TaskItem
    let document: TaskDocument
    @AppStorage(DisplaySettings.showTick) private var showTick = true
    @AppStorage(DisplaySettings.showStrikethrough) private var showStrikethrough = true

    private static let indentWidth: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            disclosure
            // The text field stays at a fixed position in the stack so it
            // keeps its identity (and focus) when a task becomes a heading.
            if !item.isHeading { checkbox }
            TaskTextField(
                text: item.title,
                font: font,
                placeholder: item.isHeading ? "Heading" : "",
                isStruckThrough: !item.isHeading && showStrikethrough && item.state != .open,
                wantsFocus: document.focusRequestID == item.id,
                onTextChange: { document.setTitle($0, for: item.id) },
                onFocus: { document.didFocus(item.id) },
                onCommand: handle
            )
        }
        .padding(.leading, CGFloat(item.depth) * Self.indentWidth)
        .padding(.top, topPadding)
        .padding(.bottom, 2)
        .opacity(item.state == .decrufted ? 0.45 : 1)
    }

    private var font: NSFont {
        switch item.headingLevel {
        case 1: .systemFont(ofSize: 22, weight: .bold)
        case 2: .systemFont(ofSize: 18, weight: .bold)
        case 3: .systemFont(ofSize: 15, weight: .semibold)
        default: TaskTextField.bodyFont
        }
    }

    /// Space above headings to separate sections.
    private var topPadding: CGFloat {
        switch item.headingLevel {
        case 1: 16
        case 2: 12
        case 3: 8
        default: 2
        }
    }

    @ViewBuilder private var disclosure: some View {
        if document.canCollapse(item.id) {
            Button {
                document.toggleCollapsed(item.id)
            } label: {
                Image(systemName: item.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isCollapsed ? "Expand" : "Collapse")
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    /// A tick box, or a plain bullet when ticks are turned off in Settings.
    /// Either way, clicking it toggles done.
    private var checkbox: some View {
        let isTicked = showTick && item.state != .open
        return Button {
            document.toggleDone(item.id)
        } label: {
            Image(systemName: symbol)
                .imageScale(showTick ? .medium : .small)
                .foregroundStyle(isTicked ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.state == .open ? "Mark done" : "Mark open")
    }

    private var symbol: String {
        let isCollapsedParent = item.isCollapsed && document.canCollapse(item.id)
        guard showTick else {
            return isCollapsedParent ? "smallcircle.filled.circle" : "circle.fill"
        }
        switch item.state {
        case .open: return isCollapsedParent ? "circle.circle" : "circle"
        case .done, .decrufted: return "checkmark.circle.fill"
        }
    }

    private func handle(_ command: TaskFieldCommand) {
        switch command {
        case .newTask: document.insertTask(after: item.id)
        case .indent: document.indent(item.id)
        case .outdent: document.outdent(item.id)
        case .focusPrevious: document.focusPrevious(from: item.id)
        case .focusNext: document.focusNext(from: item.id)
        case .deleteEmpty: document.deleteIfEmpty(item.id)
        }
    }
}

/// The list's `#` title, shown large above the tasks. Empty shows the file
/// name as a placeholder, and the file then has no `#` line.
struct ListTitleField: View {
    let document: TaskDocument

    var body: some View {
        TextField(
            document.fileName,
            text: Binding(get: { document.outline.title ?? "" }, set: { document.setListTitle($0) })
        )
        .textFieldStyle(.plain)
        .font(.system(size: 28, weight: .bold))
        .onSubmit { document.focusFirstRow() }
        .help("List title (the # line at the top of the file)")
    }
}
