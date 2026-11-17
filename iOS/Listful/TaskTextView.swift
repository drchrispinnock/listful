import SwiftUI
import UIKit

/// A row's editable text: a self-sizing `UITextView` that wraps long tasks.
/// SwiftUI's vertical `TextField` inserts Return as a line break before the
/// app sees it (the new row then showed a stray blank line), so this catches
/// line breaks in `shouldChangeTextIn` instead and hands them to
/// `ListDocument.setTitle`, which splits the row there (a paste of several
/// lines splits at each). Focus moves by `becomeFirstResponder` straight to
/// the new row's view, which keeps the keyboard up.
struct TaskTextView: UIViewRepresentable {
    let id: UUID
    let text: String
    let font: UIFont
    let isDimmed: Bool
    /// True while the document asks for this row to take focus.
    let wantsFocus: Bool
    let document: ListDocument

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text && view.markedTextRange == nil { view.text = text }
        view.font = font
        view.textColor = isDimmed ? .secondaryLabel : .label
        if wantsFocus && !view.isFirstResponder {
            // The view may not be in the window yet on the pass that made it.
            DispatchQueue.main.async { [document, id] in
                guard view.window != nil, document.focusRequest == id else { return }
                view.becomeFirstResponder()
                document.focusRequest = nil
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(height, font.lineHeight))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TaskTextView

        init(_ parent: TaskTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text.contains(where: \.isNewline), let swiftRange = Range(range, in: textView.text) else { return true }
            let edited = textView.text.replacingCharacters(in: swiftRange, with: text)
            parent.document.setTitle(edited, for: parent.id)
            textView.text = parent.document.title(of: parent.id) ?? ""
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.document.setTitle(textView.text, for: parent.id)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.document.focusedID = parent.id
            parent.document.editingID = parent.id
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.document.editingID == parent.id { parent.document.editingID = nil }
        }
    }
}
