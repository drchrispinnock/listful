import SwiftUI
import ListfulCore

struct OutlineView: View {
    @Bindable var document: TaskDocument

    /// The coordinate space row frames and drags are measured in.
    static let space = "outline"

    var body: some View {
        let rows = document.visibleItems
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: every row's text field must exist so focus can move to it.
                VStack(alignment: .leading, spacing: 2) {
                    if document.showsListTitle {
                        ListTitleField(document: document)
                            .padding(.bottom, 10)
                    }
                    ForEach(rows) { item in
                        TaskRow(item: item, document: document)
                    }
                    if rows.isEmpty {
                        Button("New Task") { document.appendTask() }
                            .padding(.top, 8)
                    }
                }
                .coordinateSpace(.named(Self.space))
                .overlay(alignment: .topLeading) { dropIndicator }
                .onPreferenceChange(RowFramesKey.self) { frames in
                    MainActor.assumeIsolated { document.rowFrames = frames }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // AppKit's own scroll-to-caret doesn't reach through SwiftUI's
            // ScrollView, so keep the row being edited in view: when focus moves
            // (Return at the bottom, arrowing down) and when its text grows onto
            // another line.
            .onChange(of: document.focusedID) { scrollToFocused(proxy) }
            .onChange(of: rows.first { $0.id == document.focusedID }?.title) { scrollToFocused(proxy) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(document.displayTitle)
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

    /// Scrolls the minimum needed to show the focused row whole. Deferred
    /// so a new or re-wrapped row has been laid out first.
    private func scrollToFocused(_ proxy: ScrollViewProxy) {
        guard let id = document.focusedID else { return }
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }

    /// Where a dragged row would land: a line at the gap, indented to the
    /// depth it would take, starting where that depth's bullet would be.
    @ViewBuilder private var dropIndicator: some View {
        if let drag = document.drag {
            HStack(spacing: 0) {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
            .padding(.leading, CGFloat(drag.depth) * TaskRow.indentWidth + TaskRow.bulletOffset)
            .offset(y: drag.gapY - 4)
            .allowsHitTesting(false)
        }
    }
}

/// Collects each row's frame, keyed by item id, for drag-and-drop.
struct RowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TaskRow: View {
    let item: TaskItem
    let document: TaskDocument
    @AppStorage(DisplaySettings.showTick) private var showTick = true
    @AppStorage(DisplaySettings.showStrikethrough) private var showStrikethrough = true

    static let indentWidth: CGFloat = 22
    /// From a row's indented edge to its bullet: the disclosure column and spacing.
    static let bulletOffset: CGFloat = 20

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
                focusCaret: document.focusRequestCaret,
                onTextChange: { document.setTitle($0, for: item.id) },
                onFocus: { document.didFocus(item.id) },
                onCommand: handle
            )
        }
        .padding(.leading, CGFloat(item.depth) * Self.indentWidth)
        .padding(.top, topPadding)
        .padding(.bottom, 2)
        .opacity(opacity)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: RowFramesKey.self,
                    value: [item.id: geometry.frame(in: .named(OutlineView.space))])
            }
        }
    }

    private var opacity: Double {
        if document.drag?.movingIDs.contains(item.id) == true { return 0.35 }
        return item.state == .decrufted ? 0.45 : 1
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
    /// Either way, clicking it toggles done, and dragging it moves the task
    /// (with its subtree): up and down to a new place, sideways to change
    /// how deeply it's nested.
    private var checkbox: some View {
        let isTicked = showTick && item.state != .open
        return Image(systemName: symbol)
            .imageScale(showTick ? .medium : .small)
            .foregroundStyle(isTicked ? Color.accentColor : Color.secondary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(OutlineView.space))
                    .onChanged { value in
                        // A small wobble is still a click.
                        let moved = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                        guard document.drag?.id == item.id || moved else { return }
                        document.updateDrag(
                            item.id, location: value.location, translation: value.translation,
                            indentWidth: Self.indentWidth)
                    }
                    .onEnded { _ in
                        if document.drag?.id == item.id {
                            document.endDrag()
                        } else {
                            document.toggleDone(item.id)
                        }
                    }
            )
            .help(item.state == .open ? "Mark done; drag to move" : "Mark open; drag to move")
            .accessibilityElement()
            .accessibilityLabel(item.state == .open ? "Mark done" : "Mark open")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { document.toggleDone(item.id) }
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
        case .newTask(let selection): document.returnKey(item.id, selection: selection)
        case .indent: document.indent(item.id)
        case .outdent: document.outdent(item.id)
        case .focusPrevious: document.focusPrevious(from: item.id)
        case .focusNext: document.focusNext(from: item.id)
        case .deleteEmpty: document.deleteIfEmpty(item.id)
        }
    }
}

/// The list's `#` title, shown large above the tasks when the file has one.
/// Clearing it removes the `#` line from the file.
struct ListTitleField: View {
    let document: TaskDocument

    var body: some View {
        TextField(
            "",
            text: Binding(get: { document.outline.title ?? "" }, set: { document.setListTitle($0) })
        )
        .textFieldStyle(.plain)
        .font(.system(size: 28, weight: .bold))
        .onSubmit { document.focusFirstRow() }
        .help("List title (the # line at the top of the file)")
    }
}
