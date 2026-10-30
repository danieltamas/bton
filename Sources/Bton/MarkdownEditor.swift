import AppKit
import SwiftUI

/// What the editor's toolbar does to the selection: wraps it in Markdown markers, or unwraps it
/// when it already carries them. GitHub renders `<ins>` underlined; Markdown has no mark for it.
@MainActor final class MarkdownEditing {
    weak var textView: NSTextView?

    enum Style: CaseIterable {
        case bold, italic, strike, underline

        var markers: (open: String, close: String) {
            switch self {
            case .bold: ("**", "**")
            case .italic: ("_", "_")
            case .strike: ("~~", "~~")
            case .underline: ("<ins>", "</ins>")
            }
        }

        var symbol: String {
            switch self {
            case .bold: "bold"
            case .italic: "italic"
            case .strike: "strikethrough"
            case .underline: "underline"
            }
        }

        var help: String {
            switch self {
            case .bold: "Bold the selection"
            case .italic: "Italic"
            case .strike: "Strike the selection through"
            case .underline: "Underline the selection"
            }
        }
    }

    /// With nothing selected the markers are inserted and the caret sits between them. The edit
    /// goes through the text view, so Undo takes it back.
    func toggle(_ style: Style) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selected = textView.selectedRange()
        let (open, close) = style.markers
        let before = NSRange(location: max(selected.location - open.utf16.count, 0), length: min(open.utf16.count, selected.location))
        let after = NSRange(location: NSMaxRange(selected), length: min(close.utf16.count, text.length - NSMaxRange(selected)))
        let wrapped = text.substring(with: before) == open && text.substring(with: after) == close
        let range = wrapped ? NSRange(location: before.location, length: NSMaxRange(after) - before.location) : selected
        let inner = text.substring(with: selected)
        let replacement = wrapped ? inner : open + inner + close
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.insertText(replacement, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + (wrapped ? 0 : open.utf16.count), length: selected.length))
        textView.window?.makeFirstResponder(textView)
    }
}

/// A plain-text Markdown editor with a selection the toolbar can reach: SwiftUI's TextEditor
/// keeps its selection to itself before macOS 15.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let editing: MarkdownEditing

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor(Theme.textPrimary)
        textView.insertionPointColor = NSColor(Theme.mint)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        editing.textView = textView
        // The editor opens with the caret in it: no second click to start typing.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
