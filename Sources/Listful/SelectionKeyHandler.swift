import AppKit
import SwiftUI

/// Holds keyboard focus while rows are selected, so keys and the Edit menu
/// act on the rows rather than on one row's text: Copy, Cut, Paste, Delete,
/// Tab and Shift-Tab, arrows to move or grow the selection, and Return or
/// Escape to go back to editing.
struct SelectionKeyHandler: NSViewRepresentable {
    let document: TaskDocument

    func makeNSView(context: Context) -> SelectionResponderView {
        SelectionResponderView()
    }

    func updateNSView(_ view: SelectionResponderView, context: Context) {
        view.document = document
        if document.selectionFocusRequested {
            // Deferred: changing focus mutates state, which isn't allowed during a view update.
            DispatchQueue.main.async {
                document.selectionFocusRequested = false
                if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
            }
        }
    }
}

final class SelectionResponderView: NSView {
    weak var document: TaskDocument?

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { document?.clearSelection() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {
        guard let document else { return }
        switch selector {
        case #selector(moveUp(_:)): document.moveSelection(by: -1)
        case #selector(moveDown(_:)): document.moveSelection(by: 1)
        case #selector(moveUpAndModifySelection(_:)): document.extendSelection(by: -1)
        case #selector(moveDownAndModifySelection(_:)): document.extendSelection(by: 1)
        case #selector(insertTab(_:)): document.indentSelection()
        case #selector(insertBacktab(_:)): document.outdentSelection()
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)): document.deleteSelection()
        case #selector(insertNewline(_:)), #selector(cancelOperation(_:)): document.editSelection()
        default: NSSound.beep()
        }
    }

    override func insertText(_ insertString: Any) {
        NSSound.beep()
    }

    @objc func copy(_ sender: Any?) { document?.copySelection() }
    @objc func cut(_ sender: Any?) { document?.cutSelection() }
    @objc func paste(_ sender: Any?) { document?.pasteOverSelection() }
    @objc func delete(_ sender: Any?) { document?.deleteSelection() }
    override func selectAll(_ sender: Any?) { document?.selectAll() }
}
