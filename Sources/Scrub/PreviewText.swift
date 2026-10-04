import AppKit
import ScrubCore
import SwiftUI

/// The text preview as an AppKit text view, whose selection can be read: what
/// is selected becomes a value to mark or a stand-in to keep the original of
/// (see `AppModel.select`), and a right-click offers the same.
struct PreviewText: NSViewRepresentable {
    let text: String
    let marks: [Mark]
    /// A value to scroll to and show, once each time it is asked for.
    var reveal: Reveal?
    let model: AppModel

    static func substring(_ text: String, _ range: Range<Int>) -> String {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    /// Where the value first stands in the preview: the first stand-in that
    /// replaced it, or one written as its stand-in, or else its original,
    /// where it was left as written.
    static func place(of reveal: Reveal, in text: String, marks: [Mark]) -> Range<Int>? {
        let original = reveal.original.lowercased(), standIn = reveal.standIn.lowercased()
        if let mark = marks.first(where: { $0.original?.lowercased() == original }) ?? marks.first(where: { substring(text, $0.range).lowercased() == standIn }) { return mark.range }
        let found = (text as NSString).range(of: reveal.original, options: .caseInsensitive)
        return found.location == NSNotFound ? nil : found.location..<NSMaxRange(found)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let view = PreviewTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        // 20 points from the edge, as the rest of the result is.
        view.textContainerInset = NSSize(width: 15, height: 16)
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PreviewTextView else { return }
        view.allowsExport = { model.selectionMayLeave }
        let model = model
        view.blocked = { model.selectionBlocked(copying: $0) }
        if context.coordinator.shown != text || context.coordinator.shownMarks != marks {
            // A new result clears the selection; that is no click of the person's.
            context.coordinator.updating = true
            context.coordinator.shown = text
            context.coordinator.shownMarks = marks
            let styled = ResultView.styled(text, marks, font: .monospacedSystemFont(ofSize: 13, weight: .regular), lineSpacing: 6)
            view.textStorage?.setAttributedString(styled)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.updating = false
        }
        if let reveal, context.coordinator.revealed != reveal {
            context.coordinator.revealed = reveal
            if let range = Self.place(of: reveal, in: text, marks: marks) {
                let shown = NSRange(location: range.lowerBound, length: range.count)
                view.scrollRangeToVisible(shown)
                view.showFindIndicator(for: shown)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PreviewText
        var shown: String?
        var shownMarks: [Mark] = []
        var updating = false
        var revealed: Reveal?
        init(_ parent: PreviewText) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView, let shown else { return }
            let range = view.selectedRange()
            parent.model.select(PreviewSelection(text: shown, marks: shownMarks, range: range.location..<NSMaxRange(range)))
        }

        /// A right-click on nothing selected picks the stand-in or word under it first.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let selected = view.selectedRange()
            if selected.length == 0 || !NSLocationInRange(charIndex, selected) {
                let under = shownMarks.first { $0.range.contains(charIndex) }.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) }
                view.setSelectedRange(under ?? view.selectionRange(forProposedRange: NSRange(location: charIndex, length: 0), granularity: .selectByWord))
            }
            return PreviewMenu.make(parent.model)
        }
    }
}

/// A text view that lets a selection leave the app (copied, dragged or sent
/// to a service) only when `allowsExport` says so at that moment
/// (`AppModel.selectionMayLeave`): once the result may leave, and not while
/// changes to it are still being written in. Until then
/// its menu's Copy, ⌘C, a drag out of the window and a service write nothing,
/// and `blocked` opens the review instead.
final class PreviewTextView: NSTextView {
    var allowsExport: () -> Bool = { false }
    /// Called when a selection tried to leave: `true` for a copy, `false` for a drag or a service.
    var blocked: (Bool) -> Void = { _ in }

    // The context menu's Copy, and ⌘C once the menu command sends it here.
    override func copy(_ sender: Any?) {
        guard allowsExport() else { blocked(true); return }
        super.copy(sender)
    }

    // A drag out of the window starts nothing until then.
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        guard allowsExport() else { blocked(false); return false }
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }

    // Copy, drag and services all write the selection through here.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard allowsExport() else { blocked(pboard.name == .general); return false }
        return super.writeSelection(to: pboard, types: types)
    }

    // Services ("New Note With Selection") find no text to take.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard allowsExport() || sendType == nil else { return nil }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}

/// One table cell, selectable like the text preview. Only its first line is
/// shown; a selection in it is read against the cell as shown.
struct PreviewCell: NSViewRepresentable {
    let text: String
    let marks: [Mark]
    let column: String?
    let model: AppModel

    func makeNSView(context: Context) -> PreviewField {
        let field = PreviewField(labelWithString: "")
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: PreviewField, context: Context) {
        field.editor.allowsExport = { model.selectionMayLeave }
        let model = model, text = text, marks = marks, column = column
        field.editor.blocked = { model.selectionBlocked(copying: $0) }
        field.onSelect = { range in model.select(PreviewSelection(text: text, marks: marks, range: range, key: column)) }
        field.onMenu = { PreviewMenu.make(model) }
        field.marks = marks
        if field.stringValue != text {
            field.attributedStringValue = ResultView.styled(text, marks, font: .systemFont(ofSize: 13))
        }
    }
}

/// A label whose text can be selected. Its field editor is its own, so the
/// selection is read here, and leaves the app only as the text preview's does.
final class PreviewField: NSTextField {
    let editor: PreviewTextView = {
        let editor = PreviewTextView()
        editor.isFieldEditor = true
        return editor
    }()
    var marks: [Mark] = []
    var onSelect: ((Range<Int>) -> Void)?
    var onMenu: (() -> NSMenu?)?

    override class var cellClass: AnyClass? {
        get { PreviewFieldCell.self }
        set {}
    }

    @objc func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        let range = view.selectedRange()
        onSelect?(range.location..<NSMaxRange(range))
    }

    /// A right-click on a cell with nothing selected in it picks the whole cell.
    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?(0..<(stringValue as NSString).length)
        return onMenu?() ?? super.menu(for: event)
    }

    @objc func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        let selected = view.selectedRange()
        if selected.length == 0 || !NSLocationInRange(charIndex, selected) {
            let under = marks.first { $0.range.contains(charIndex) }.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) }
            view.setSelectedRange(under ?? view.selectionRange(forProposedRange: NSRange(location: charIndex, length: 0), granularity: .selectByWord))
        }
        return onMenu?() ?? menu
    }
}

final class PreviewFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? PreviewField)?.editor ?? super.fieldEditor(for: controlView)
    }
}

/// The right-click menu over a selection: replace what Scrub missed, or keep
/// what it replaced, and copy, which asks the export gate as ⌘C does.
@MainActor
enum PreviewMenu {
    static func make(_ model: AppModel) -> NSMenu {
        let menu = NSMenu()
        let pick = model.pick
        if !pick.missed.isEmpty {
            menu.addItem(Action("Replace \(Copy.quoted(pick.missed)) as \(Copy.kind(model.markKind))", key: "e") { model.applySelection() })
            let kinds = NSMenu()
            for kind in Marks.kinds { kinds.addItem(Action(Copy.kind(kind)) { model.markKind = kind; model.applySelection() }) }
            let other = NSMenuItem(title: "Replace as", action: nil, keyEquivalent: "")
            other.submenu = kinds
            menu.addItem(other)
        } else if !pick.isEmpty {
            let title = pick.replaced.isEmpty ? Copy.removeMark : Copy.keepOriginal(ResultView.originals(of: pick))
            menu.addItem(Action(title, key: "e") { model.keepOriginal() })
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(Action("Copy", key: "c") { model.copyCommand() })
        return menu
    }

    /// A menu item that runs a closure.
    private final class Action: NSMenuItem {
        private let run: () -> Void
        init(_ title: String, key: String = "", run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(runAction), keyEquivalent: key)
            target = self
        }
        required init(coder: NSCoder) { fatalError("not used") }
        @objc private func runAction() { run() }
    }
}
