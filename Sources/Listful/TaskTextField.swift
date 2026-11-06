import AppKit
import SwiftUI

/// Outliner keystrokes intercepted from a row's text field.
enum TaskFieldCommand {
    /// Return, with the selection (UTF-16 offsets) to split the task at.
    case newTask(selection: Range<Int>)
    /// Delete with the caret at the very start.
    case deleteAtStart
    case indent, outdent, focusPrevious, focusNext
    /// Shift-Up/Down: select rows instead of editing text.
    case extendSelection(up: Bool)
    /// Escape: select this row.
    case selectRow
    /// Text with line breaks pasted (or dropped) in: becomes tasks.
    case pasteLines(String)
    /// Shift-click on a row that isn't being edited, or a drag across rows
    /// reaching this one: extend the selection to it.
    case shiftClick
}

/// A borderless NSTextField that wraps long titles onto further lines. SwiftUI's TextField can't intercept
/// Tab/Shift-Tab before AppKit uses them for focus traversal, so this goes
/// through the field editor's `doCommandBy` instead.
struct TaskTextField: NSViewRepresentable {
    var text: String
    var font: NSFont = Self.bodyFont
    var placeholder: String = ""
    var isStruckThrough: Bool
    /// A pending one-shot focus request for this row; `onFocus` acknowledges it.
    var wantsFocus: Bool
    /// Where to put the caret on taking focus (UTF-16 offset); nil is the end.
    var focusCaret: Int?
    var onTextChange: (String) -> Void
    var onFocus: () -> Void
    var onCommand: (TaskFieldCommand) -> Void

    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusReportingTextField {
        let field = FocusReportingTextField()
        field.delegate = context.coordinator
        field.onCommand = { [weak coordinator = context.coordinator] in coordinator?.parent.onCommand($0) }
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.placeholderString = placeholder
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: FocusReportingTextField, context: Context) {
        context.coordinator.parent = self
        field.onFocus = onFocus

        if field.font != font {
            field.font = font
            field.invalidateIntrinsicContentSize()
        }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }

        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != text {
            field.stringValue = text
        }
        applyStyle(to: field, editor: editor)

        if wantsFocus {
            // Deferred: the view may not be in a window yet, and reporting
            // focus mutates state, which isn't allowed during a view update.
            DispatchQueue.main.async {
                if field.currentEditor() == nil {
                    guard let window = field.window else { return }
                    window.makeFirstResponder(field)
                }
                // Also when already focused: a split may have just changed its text.
                guard let editor = field.currentEditor() else { return }
                let length = field.stringValue.utf16.count
                editor.selectedRange = NSRange(location: min(focusCaret ?? length, length), length: 0)
                // becomeFirstResponder reports focus itself; this covers the
                // already-focused case, and acknowledging twice is harmless.
                onFocus()
            }
        }
    }

    /// Fills the offered width and grows tall enough for the wrapped text.
    /// Measured on a copy of the cell, since the live one may be mid-edit.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: FocusReportingTextField, context: Context) -> CGSize? {
        guard let cell = field.cell?.copy() as? NSCell else { return nil }
        // A space keeps an empty row one line tall.
        cell.attributedStringValue = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        guard let width = proposal.width, width.isFinite else {
            return cell.cellSize
        }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    private func applyStyle(to field: NSTextField, editor: NSTextView?) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if isStruckThrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        } else {
            attributes[.foregroundColor] = NSColor.labelColor
        }

        if let editor, let storage = editor.textStorage {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            editor.typingAttributes = attributes
        } else {
            field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TaskTextField

        init(_ parent: TaskTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onTextChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: TaskFieldCommand
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let selection = textView.selectedRange()
                command = .newTask(selection: selection.location..<(selection.location + selection.length))
            case #selector(NSResponder.insertTab(_:)): command = .indent
            case #selector(NSResponder.insertBacktab(_:)): command = .outdent
            case #selector(NSResponder.moveUp(_:)): command = .focusPrevious
            case #selector(NSResponder.moveDown(_:)): command = .focusNext
            case #selector(NSResponder.moveUpAndModifySelection(_:)): command = .extendSelection(up: true)
            case #selector(NSResponder.moveDownAndModifySelection(_:)): command = .extendSelection(up: false)
            // Escape arrives as cancelOperation:, which a text view turns into complete:.
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): command = .selectRow
            case #selector(NSResponder.deleteBackward(_:)) where textView.selectedRange() == NSRange(location: 0, length: 0):
                command = .deleteAtStart
            default: return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

/// Tells the row when it gains focus by click, so the document's
/// `focusedID` follows the user and menu commands target the right task.
/// Also passes on Shift-clicks and drags across rows, for selecting rows.
final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?
    var onCommand: ((TaskFieldCommand) -> Void)?

    override class var cellClass: AnyClass? {
        get { TaskFieldCell.self }
        set {}
    }

    override func mouseDown(with event: NSEvent) {
        // Once editing, clicks go to the field editor instead.
        if event.modifierFlags.contains(.shift), let onCommand {
            onCommand(.shiftClick)
            return
        }
        if !RowDragTracker.track(event, from: self) { super.mouseDown(with: event) }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// Gives every row the same `TaskFieldEditor` in place of the window's.
final class TaskFieldCell: NSTextFieldCell {
    @MainActor private static let editor: TaskFieldEditor = {
        let editor = TaskFieldEditor()
        editor.isFieldEditor = true
        // As the window's own field editor has, for Cmd-Z while typing.
        editor.allowsUndo = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        Self.editor
    }
}

/// The text view that edits a row. It turns a drag that leaves the row
/// into selecting rows, and pasted text with line breaks, which a row
/// can't hold, into tasks.
final class TaskFieldEditor: NSTextView {
    private var field: FocusReportingTextField? { delegate as? FocusReportingTextField }

    override func mouseDown(with event: NSEvent) {
        guard let field, RowDragTracker.track(event, from: field) else {
            super.mouseDown(with: event)
            return
        }
    }

    // Typing can't produce a line break (Return is a command), so one
    // here means a paste or a drop.
    override func shouldChangeText(in range: NSRange, replacementString string: String?) -> Bool {
        if let string, string.contains(where: \.isNewline), let onCommand = field?.onCommand {
            onCommand(.pasteLines(string))
            return false
        }
        return super.shouldChangeText(in: range, replacementString: string)
    }
}

/// Decides whether a press in a row's text is a click, a drag to select
/// text, or a drag across rows to select them, by watching the first
/// moves itself. A click or text drag is handed back: the events seen so
/// far are put back in the queue for the text view's own tracking.
@MainActor
enum RowDragTracker {
    /// Returns true if it handled the press as a drag across rows.
    static func track(_ down: NSEvent, from field: FocusReportingTextField) -> Bool {
        guard down.clickCount == 1, let window = field.window, let onCommand = field.onCommand else { return false }
        let start = field.convert(down.locationInWindow, from: nil)
        var seen: [NSEvent] = []
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            seen.append(event)
            let point = field.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp || abs(point.x - start.x) > 3 && field.bounds.contains(point) {
                // A click, or a drag along the text.
                for event in seen.reversed() { NSApp.postEvent(event, atStart: true) }
                return false
            }
            if point.y < field.bounds.minY || point.y > field.bounds.maxY { break }
        }
        onCommand(.selectRow)
        var last: FocusReportingTextField? = field
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged {
            field.autoscroll(with: event)
            let hit = window.contentView?.hitTest(event.locationInWindow)
            if let row = hit.flatMap(enclosingRow), row !== last {
                row.onCommand?(.shiftClick)
                last = row
            }
        }
        return true
    }

    /// The row field `view` is part of, if any.
    private static func enclosingRow(of view: NSView) -> FocusReportingTextField? {
        var view: NSView? = view
        while let current = view {
            if let row = current as? FocusReportingTextField { return row }
            view = current.superview
        }
        return nil
    }
}
