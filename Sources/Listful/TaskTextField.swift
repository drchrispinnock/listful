import AppKit
import SwiftUI

/// Outliner keystrokes intercepted from a row's text field.
enum TaskFieldCommand {
    /// Return, with the selection (UTF-16 offsets) to split the task at.
    case newTask(selection: Range<Int>)
    case indent, outdent, focusPrevious, focusNext, deleteEmpty
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
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty: command = .deleteEmpty
            default: return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

/// Tells the row when it gains focus by click, so the document's
/// `focusedID` follows the user and menu commands target the right task.
final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
