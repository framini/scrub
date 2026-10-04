import AppKit
import Observation
import ScrubCore
import UniformTypeIdentifiers

enum Source { case file, paste }

struct Finished {
    let name: String
    let source: Source
    /// What Copy and Save write: the scrub with the findings the person chose to leave taken back.
    var result: ScrubResult
    var savedAs: String?
    var copied = false
    /// What to leave as written, everywhere or place by place, and whether the
    /// person has looked. A value Scrub left as written starts so.
    var choices = Choices()
    /// Values the person marked for Scrub to replace too; kept for this file only.
    var marks = Marks()
    /// Kinds and replacements the person changed; kept for this file only, as the marks are.
    var edits = Edits()
    var reviewed = false
    var needsReview: Bool { !reviewed && !result.uncertain.isEmpty }
    /// Whether anything of the result may leave the app yet: whole, as a
    /// selection, or saved. Every way out asks this one question (see `AppModel.cleared`).
    var mayExport: Bool { !needsReview }
}

enum Shortcut { case copy, save }

/// A selection in the preview: the text shown there (the output, or one
/// table cell), the stand-ins in it, what is selected, and the column it sits under.
struct PreviewSelection {
    let text: String
    let marks: [Mark]
    let range: Range<Int>
    var key: String?
}

/// One state of the person's own changes: what to leave, what they marked,
/// the kinds and replacements they changed, whether the review was done, and
/// what the change that made it was called (for the Edit menu). Undoing a
/// review asks for it again before anything leaves.
struct Step {
    let choices: Choices
    let marks: Marks
    var edits = Edits()
    var reviewed: Bool
    let name: String
}

/// The editor for one value: what it replaced, the kind it is read as and
/// the stand-in written for it, each the person's to change before applying.
struct Draft: Equatable {
    enum Source { case preview, panel }
    /// Every finding of the value, as Scrub made them, or the one mark.
    let targets: [Finding]
    let original: String
    let places: Int
    let byHand: Bool
    let source: Source
    let initialKind: String
    let initialText: String
    var kind: String
    var text: String
    /// Why the text typed was refused, shown beside it until it changes.
    var refusal: Refusal?

    var changed: Bool { kind != initialKind || text != initialText }
}

/// A value to find in the preview: scrolled to and shown, once per request.
struct Reveal: Equatable {
    let original: String
    let standIn: String
    let count: Int
}

/// What the last change did, said under the preview with the way back.
struct Notice: Equatable {
    let text: String
    /// Undo when the change was just made, Redo when it was just undone.
    let undone: Bool
}

struct ShortcutPulse: Equatable {
    let shortcut: Shortcut
    let count: Int
}

enum ViewState {
    case idle
    case processing(name: String, source: Source, stage: Stage, done: Int, total: Int)
    case finished(Finished)
    case failed(name: String, source: Source, code: String)
}

@MainActor
@Observable
final class AppModel {
    static let maxBytes = 50 * 1024 * 1024
    static let pastedName = "Pasted text"

    private(set) var state: ViewState = .idle
    private(set) var pulse: ShortcutPulse?
    var failedSave = false
    /// The review of uncertain findings is open; `afterReview` runs once it is done.
    var reviewing = false
    private var afterReview: Shortcut?
    private(set) var applyingReview = false
    /// What the preview's selection stands on, and the kind its missed values
    /// are marked as: guessed with each selection, and the person's to change.
    private(set) var pick = Pick()
    var markKind = "PERSON"
    /// The person's changes, oldest first, and the one the result is (or is
    /// being) written with. Undo and redo move along it; a new change drops
    /// what was undone. Kept for this file only, as the marks are.
    private var history: [Step] = []
    private var position = 0
    private(set) var notice: Notice?
    /// The editor open for one value, from a click on its stand-in or its row in the Values panel.
    var draft: Draft?
    /// The Values panel: every value, to find, filter and change, and which rows are selected.
    private(set) var showingValues = false
    var valueSearch = ""
    /// A kind as `Copy.kind` names it, or nil for every kind.
    var valueKind: String?
    var valueFilter = ValueFilter.all
    private(set) var selectedValues: Set<Finding.ID> = []
    private var selectionAnchor: Finding.ID?
    /// The row last clicked or moved to with the arrow keys, kept in view.
    private(set) var valueCursor: Finding.ID?
    /// Every value as the result writes it, one row each; built once per result.
    private(set) var values: [ValueRow] = []
    /// The value the preview should scroll to and show.
    private(set) var reveal: Reveal?
    /// A value whose places are being chosen one by one, from the Values panel.
    var placing: Finding?
    /// Copy or Save asked for while the result is being written again; run once it is.
    private var afterRewrite: Shortcut?
    private var rewrites = 0

    // Clear, and any newer input, bumps the generation; work finishing after
    // that is dropped, so cleared content never comes back.
    private var generation = 0
    private var work: Task<Void, Never>?
    private var copiedChangeCount: Int?
    private var copyResets = 0
    private let board: NSPasteboard
    typealias Scrub = @Sendable (Data, String, @escaping (Stage, Int, Int) -> Void) throws -> ScrubResult
    private let scrub: Scrub

    init(board: NSPasteboard = .general, scrub: @escaping Scrub = { data, name, progress in try Scrubber.scrub(data, name: name, progress: progress) }) {
        self.board = board
        self.scrub = scrub
    }

    func ticket() -> Int { generation }

    func beginDrop() -> Int {
        stop()
        return ticket()
    }

    func open(_ url: URL, ticket: Int) {
        guard ticket == generation else { return }
        open(url)
    }

    func clear() {
        stop()
        releaseClipboard()
        failedSave = false
        state = .idle
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else { return fail(name, .file, "too_large") }
        guard let data = try? Data(contentsOf: url) else { return fail(name, .file, "unreadable") }
        start(name, .file, data)
    }

    func paste() {
        guard let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let holdsSomething = !(board.types ?? []).isEmpty
            return fail(Self.pastedName, .paste, holdsSomething ? "clipboard_not_text" : "empty_clipboard")
        }
        start(Self.pastedName, .paste, Data(text.utf8))
    }

    // A key press never shows a button's pressed state, so shortcuts signal
    // the button to play it.
    func viaShortcut(_ shortcut: Shortcut) {
        guard case .finished = state else { return }
        pulse = ShortcutPulse(shortcut: shortcut, count: (pulse?.count ?? 0) + 1)
        switch shortcut {
        case .copy: copy()
        // The save panel runs modally; let the press show before it opens.
        case .save: Task { try? await Task.sleep(for: .milliseconds(150)); save() }
        }
    }

    /// The one gate every way out of the app passes: Copy, ⌘C on a selection
    /// or on the whole result, and Save. While uncertain findings wait to be
    /// checked, it opens the review instead, and `then` runs once it is done.
    /// The preview can always be selected; copying, dragging or sharing a
    /// selection waits for this gate too (`PreviewTextView`, `selectionBlocked`).
    /// While marks or choices are being written in, it waits for them, so
    /// nothing leaves without them.
    private func cleared(then shortcut: Shortcut) -> Bool {
        guard case .finished(let done) = state else { return false }
        if applyingReview {
            afterRewrite = shortcut
            return false
        }
        if done.mayExport { return true }
        if !reviewing { review(then: shortcut) }
        return false
    }

    /// Whether a selection in the preview may leave right now. Asked at the
    /// moment it would be copied, dragged or sent to a service, never kept:
    /// while marks or choices are being written in, the preview still shows
    /// the text without them, so nothing of it leaves until they are.
    var selectionMayLeave: Bool {
        guard case .finished(let done) = state else { return false }
        return done.mayExport && !applyingReview
    }

    /// A selection in the preview tried to leave while the result waits for
    /// review: its menu's Copy (`copying`), a drag or a service. Nothing was
    /// written; the review opens, and a copy then copies the result, as ⌘C does.
    func selectionBlocked(copying: Bool) {
        guard case .finished(let done) = state, !done.mayExport, !reviewing else { return }
        review(then: copying ? .copy : nil)
    }

    /// ⌘C copies a selection when the focused view has one, and otherwise the
    /// whole result. A responder with nothing selected leaves the pasteboard
    /// untouched, which is how the two cases are told apart. While the result
    /// waits for review a selection copies nothing, and ⌘C asks first.
    func copyCommand(sendCopy: () -> Bool = { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }) {
        if case .finished = state, !cleared(then: .copy) { return }
        let before = board.changeCount
        if sendCopy(), board.changeCount != before {
            copiedChangeCount = board.changeCount
            return
        }
        viaShortcut(.copy)
    }

    /// Opens the review of uncertain findings; `then` copies or saves once it is done.
    func review(then shortcut: Shortcut? = nil) {
        guard case .finished = state else { return }
        afterReview = shortcut
        reviewing = true
    }

    func cancelReview() {
        afterReview = nil
        reviewing = false
    }

    /// Writes the result again as `choices` say, always from the scrub as
    /// first made, then copies or saves if asked.
    func finishReview(_ choices: Choices) {
        guard case .finished = state, let latest else { return }
        reviewing = false
        let next = afterReview
        afterReview = nil
        // A review that changes nothing is no change to undo; it is done all the same.
        if choices != latest.choices { record(Step(choices: choices, marks: latest.marks, edits: latest.edits, reviewed: true, name: "Review Choices")) } else { history[position].reviewed = true }
        notice = nil
        rewrite(history[position], then: next)
    }

    /// Reads what a selection in the preview stands on; nil clears it. A
    /// click on one value's stand-in opens its editor.
    func select(_ selection: PreviewSelection?) {
        guard case .finished(let done) = state, let selection else {
            pick = Pick()
            if draft?.source == .preview { draft = nil }
            return
        }
        pick = done.result.pick(in: selection.text, marks: selection.marks, range: selection.range)
        if !pick.isEmpty { notice = nil }
        if let first = pick.missed.first { markKind = Marks.guess(first, key: selection.key) }
        draft = Self.draft(for: pick, in: done)
    }

    /// The editor for what `pick` stands on, when that is one value's stand-in.
    private static func draft(for pick: Pick, in done: Finished) -> Draft? {
        guard pick.missed.isEmpty, !pick.isEmpty, ResultView.originals(of: pick).count == 1 else { return nil }
        if let first = pick.replaced.first {
            let shown = done.result.revised(first)
            return Draft(targets: pick.replaced, original: first.original, places: pick.replaced.reduce(0) { $0 + $1.places.count }, byHand: false, source: .preview,
                         initialKind: shown.entity, initialText: shown.standIn, kind: shown.entity, text: shown.standIn)
        }
        guard let entry = pick.marked.first, let mine = done.result.byHand.first(where: { $0.original == entry.text && $0.entity == entry.entity }) else { return nil }
        return draft(for: mine, source: .preview)
    }

    private static func draft(for finding: Finding, source: Draft.Source) -> Draft {
        Draft(targets: [finding], original: finding.original, places: finding.places.count, byHand: finding.id < 0, source: source,
              initialKind: finding.entity, initialText: finding.standIn, kind: finding.entity, text: finding.standIn)
    }

    /// Esc in the editor: closes it and changes nothing.
    func cancelDraft() {
        guard let draft else { return }
        self.draft = nil
        if draft.source == .preview { pick = Pick() }
    }

    /// ⏎ in the editor: reads the value as the kind chosen and writes the
    /// replacement typed, everywhere it stands. A replacement that is unsafe
    /// is refused, with why, and nothing is written.
    func applyDraft() {
        guard case .finished(let done) = state, var draft, let latest, !applyingReview else { return }
        guard draft.changed else { return cancelDraft() }
        let kind = draft.kind != draft.initialKind ? draft.kind : nil
        let typed = draft.text != draft.initialText ? draft.text : nil
        let edited: (Choices, Marks, Edits)
        do {
            edited = try done.result.editing(draft.targets, kind: kind, replacement: typed, choices: latest.choices, marks: latest.marks, edits: latest.edits)
        } catch {
            draft.refusal = error as? Refusal ?? .empty
            self.draft = draft
            return
        }
        let (choices, marks, edits) = edited
        let (original, places) = (draft.original, draft.places)
        record(Step(choices: choices, marks: marks, edits: edits, reviewed: latest.reviewed, name: Copy.editStep(original, kind: kind, replacement: typed)))
        self.draft = nil
        rewrite(history[position]) { _ in Notice(text: Copy.edited(original, kind: kind, replacement: typed, places: places), undone: false) }
    }

    // MARK: Values panel

    /// ⇧⌘L: shows or hides the Values panel.
    func toggleValues() {
        guard case .finished = state else { return }
        showingValues.toggle()
        if !showingValues { clearValueSelection() }
    }

    /// Shows the Values panel with only `filter`'s rows, as the footer's count of your changes does.
    func showValues(_ filter: ValueFilter) {
        guard case .finished = state else { return }
        valueFilter = filter
        showingValues = true
    }

    private func clearValueSelection() {
        selectedValues = []
        selectionAnchor = nil
        valueCursor = nil
        if draft?.source == .panel { draft = nil }
    }

    /// The rows the search, kind and status filters leave, in the order Scrub met them.
    var visibleValues: [ValueRow] {
        let query = ValueRow.fold(valueSearch.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty || valueKind != nil || valueFilter != .all else { return values }
        return values.filter { row in
            (valueKind == nil || Copy.kind(row.finding.entity) == valueKind) && valueFilter.admits(row) && (query.isEmpty || row.search.contains(query))
        }
    }

    /// The kinds the rows hold, as `Copy.kind` names them, for the kind filter.
    var valueKinds: [String] {
        var seen: Set<String> = []
        return values.map { Copy.kind($0.finding.entity) }.filter { seen.insert($0).inserted }.sorted()
    }

    /// A click on a row: selects it alone, or with ⌘ adds or takes it away,
    /// or with ⇧ selects every row from the last one clicked. One row
    /// selected opens its editor, and the preview shows it.
    func selectValue(_ id: Finding.ID, toggling: Bool = false, extending: Bool = false) {
        let shown = visibleValues
        if extending, let anchor = selectionAnchor, let from = shown.firstIndex(where: { $0.id == anchor }), let to = shown.firstIndex(where: { $0.id == id }) {
            selectedValues = Set(shown[min(from, to)...max(from, to)].map(\.id))
        } else if toggling {
            if selectedValues.contains(id) { selectedValues.remove(id) } else { selectedValues.insert(id) }
            selectionAnchor = id
        } else {
            selectedValues = [id]
            selectionAnchor = id
        }
        valueCursor = id
        // Rows the filters hide stay unselected.
        selectedValues.formIntersection(shown.map(\.id))
        valuesSelected()
    }

    /// ↑ or ↓ in the Values panel: selects the row above or below the last
    /// one clicked or moved to (the first or the last with nothing selected
    /// yet), with ⇧ every row from where the selection started, and with ⌘
    /// the first or the last row.
    func moveValueSelection(by step: Int, extending: Bool = false, toEnd: Bool = false) {
        let shown = visibleValues
        guard !shown.isEmpty, step != 0 else { return }
        let index: Int
        if toEnd {
            index = step < 0 ? 0 : shown.count - 1
        } else if let cursor = valueCursor, let at = shown.firstIndex(where: { $0.id == cursor }) {
            index = min(max(at + step, 0), shown.count - 1)
        } else {
            index = step < 0 ? shown.count - 1 : 0
        }
        selectValue(shown[index].id, extending: extending)
    }

    /// Selects every row the filters leave.
    func selectAllValues() {
        selectedValues = Set(visibleValues.map(\.id))
        valuesSelected()
    }

    private func valuesSelected() {
        guard selectedValues.count == 1, let id = selectedValues.first, let row = values.first(where: { $0.id == id }) else {
            if draft?.source == .panel || selectedValues.count > 1 { draft = nil }
            return
        }
        notice = nil
        pick = Pick()
        draft = Self.draft(for: row.finding, source: .panel)
        reveal = Reveal(original: row.finding.original, standIn: row.finding.standIn, count: (reveal?.count ?? 0) + 1)
    }

    /// The selected rows' values, as Scrub made them (a mark as the person made it).
    private func targets(_ ids: Set<Finding.ID>) -> [Finding] {
        guard case .finished(let done) = state else { return [] }
        let made = done.result.findings
        return values.filter { ids.contains($0.id) }.map { row in row.id >= 0 && made.indices.contains(row.id) ? made[row.id] : row.finding }
    }

    /// Reads the selected values as `kind`, each with a new stand-in of that kind.
    func changeKind(of ids: Set<Finding.ID>, to kind: String) {
        guard case .finished(let done) = state, let latest, !applyingReview else { return }
        let chosen = targets(ids).filter { done.result.revised($0).entity != kind }
        guard !chosen.isEmpty else { return }
        guard let edited = try? done.result.editing(chosen, kind: kind, replacement: nil, choices: latest.choices, marks: latest.marks, edits: latest.edits) else { return }
        let (choices, marks, edits) = edited
        let originals = chosen.map(\.original), places = chosen.reduce(0) { $0 + $1.places.count }
        record(Step(choices: choices, marks: marks, edits: edits, reviewed: latest.reviewed, name: Copy.editStep(originals, kind: kind)))
        rewrite(history[position]) { _ in Notice(text: Copy.changed(originals, to: kind, places: places), undone: false) }
    }

    /// Leaves the selected values as written everywhere, and takes the selected marks off.
    func keepValues(_ ids: Set<Finding.ID>) {
        guard case .finished(let done) = state, let latest, !applyingReview else { return }
        let chosen = targets(ids)
        guard !chosen.isEmpty else { return }
        let (choices, marks) = done.result.keeping(chosen, choices: latest.choices, marks: latest.marks)
        let originals = chosen.map(\.original), places = chosen.reduce(0) { $0 + $1.places.count }
        let unmarking = chosen.allSatisfy { $0.id < 0 }
        record(Step(choices: choices, marks: marks, edits: latest.edits, reviewed: latest.reviewed, name: unmarking ? "Remove Mark on \(Copy.quoted(originals))" : Copy.keepOriginal(originals)))
        rewrite(history[position]) { _ in Notice(text: Copy.kept(originals, places: places, unmarking: unmarking), undone: false) }
    }

    /// Replaces the selected values again wherever they were left as written.
    func replaceValuesAgain(_ ids: Set<Finding.ID>) {
        guard case .finished = state, let latest, !applyingReview else { return }
        let chosen = targets(ids)
        var choices = latest.choices
        for finding in chosen { choices.set(finding, leave: false) }
        guard choices != latest.choices else { return }
        let originals = chosen.map(\.original)
        let places = chosen.reduce(0) { total, finding in total + finding.places.filter { latest.choices.leaves($0, of: finding) }.count }
        record(Step(choices: choices, marks: latest.marks, edits: latest.edits, reviewed: latest.reviewed, name: Copy.replaceAgainStep(originals)))
        rewrite(history[position]) { _ in Notice(text: Copy.replacedAgain(originals, places: places), undone: false) }
    }

    /// Opens the choice of one value's places, one by one.
    func choosePlaces(_ id: Finding.ID) {
        placing = values.first { $0.id == id }?.finding
    }

    /// Writes the choices made place by place for one value.
    func finishPlaces(_ choices: Choices) {
        guard let placing, let latest else { return }
        self.placing = nil
        guard choices != latest.choices else { return }
        record(Step(choices: choices, marks: latest.marks, edits: latest.edits, reviewed: latest.reviewed, name: Copy.placesStep(placing.original)))
        rewrite(history[position]) { _ in Notice(text: Copy.chosePlaces(placing.original), undone: false) }
    }

    /// ⌘E: replaces what the selection holds that Scrub missed, or else keeps
    /// the originals of the stand-ins it is on.
    func applySelection() {
        if !pick.missed.isEmpty { mark(pick.missed, as: markKind) } else if !pick.isEmpty { keepOriginal() }
        else if showingValues, !selectedValues.isEmpty { keepValues(selectedValues) }
    }

    /// The editor's Keep original, or Remove mark for the person's own.
    func keepDraft() {
        guard let draft else { return }
        if draft.source == .preview, !pick.isEmpty { keepOriginal() } else { keepValues(Set(draft.targets.map(\.id))) }
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    /// Replaces `texts` as `entity` everywhere they and their variants are written.
    func mark(_ texts: [String], as entity: String) {
        guard case .finished(let done) = state, !texts.isEmpty, let latest else { return }
        let (choices, marks) = done.result.marking(texts, as: entity, choices: latest.choices, marks: latest.marks)
        let keys = Set(texts.map { $0.lowercased() })
        record(Step(choices: choices, marks: marks, edits: latest.edits, reviewed: latest.reviewed, name: "Replace \(Copy.quoted(texts))"))
        rewrite(history[position]) { revised in
            let places = revised.byHand.filter { keys.contains($0.original.lowercased()) }.reduce(0) { $0 + $1.places.count }
            return Notice(text: Copy.replaced(texts, places: places, as: entity), undone: false)
        }
    }

    /// Leaves what the selection's stand-ins replaced as written, everywhere,
    /// and takes back the marks it is on.
    func keepOriginal() {
        guard case .finished(let done) = state, !pick.isEmpty, let latest else { return }
        let picked = pick
        let (choices, marks) = done.result.keeping(picked, choices: latest.choices, marks: latest.marks)
        let unmarked = Set(picked.marked.map(\.text))
        let places = (picked.replaced + done.result.byHand.filter { unmarked.contains($0.original) }).reduce(0) { $0 + $1.places.count }
        let originals = ResultView.originals(of: picked)
        let unmarking = picked.replaced.isEmpty
        record(Step(choices: choices, marks: marks, edits: latest.edits, reviewed: latest.reviewed, name: unmarking ? "Remove Mark on \(Copy.quoted(originals))" : Copy.keepOriginal(originals)))
        rewrite(history[position]) { _ in Notice(text: Copy.kept(originals, places: places, unmarking: unmarking), undone: false) }
    }

    var canUndo: Bool { position > 0 && !reviewing }
    var canRedo: Bool { position + 1 < history.count && !reviewing }
    /// The Edit menu's titles, naming the change: "Undo Replace “zephyrine”".
    var undoTitle: String { canUndo ? "Undo \(history[position].name)" : "Undo" }
    var redoTitle: String { canRedo ? "Redo \(history[position + 1].name)" : "Redo" }

    /// ⌘Z: writes the result as it was before the last change.
    func undo() {
        guard canUndo else { return }
        let name = history[position].name
        position -= 1
        rewrite(history[position]) { _ in Notice(text: Copy.undid(name), undone: true) }
    }

    /// ⇧⌘Z: makes the change undone last again.
    func redo() {
        guard canRedo else { return }
        position += 1
        let name = history[position].name
        rewrite(history[position]) { _ in Notice(text: Copy.redid(name), undone: false) }
    }

    /// The state the result is written with, or is being written with now.
    private var latest: Step? { history.indices.contains(position) ? history[position] : nil }

    private func record(_ step: Step) {
        history = Array(history.prefix(position + 1)) + [step]
        // A long session keeps its last hundred changes.
        if history.count > 101 { history.removeFirst(history.count - 101) }
        position = history.count - 1
    }

    /// Writes the result again as `step` says, always from the scrub as first
    /// made, then copies or saves if asked, and says what changed. A newer
    /// rewrite replaces one still running.
    private func rewrite(_ step: Step, then next: Shortcut? = nil, notice told: (@MainActor @Sendable (ScrubResult) -> Notice?)? = nil) {
        guard case .finished(let done) = state else { return }
        let (choices, marks, edits, reviewed) = (step.choices, step.marks, step.edits, step.reviewed)
        let ticket = generation
        let result = done.result
        rewrites += 1
        let mine = rewrites
        pick = Pick()
        notice = nil
        draft = nil
        applyingReview = true
        work?.cancel()
        work = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { try result.applying(choices, marks: marks, edits: edits) }
            // Built here, off the main thread, so thousands of values never hold up the window.
            let rows = (try? outcome.get()).map { ValueRow.rows(of: $0, choices: choices, edits: edits, reviewed: reviewed) }
            await MainActor.run {
                guard let self, self.generation == ticket, self.rewrites == mine, case .finished(var current) = self.state else { return }
                self.applyingReview = false
                let after = next ?? self.afterRewrite
                self.afterRewrite = nil
                switch outcome {
                case .success(let revised):
                    current.result = revised
                    current.choices = choices
                    current.marks = marks
                    current.edits = edits
                    current.reviewed = reviewed
                    current.copied = false
                    self.state = .finished(current)
                    self.values = rows ?? []
                    // A row still selected alone opens again, as it now reads; a value marked again has a new row.
                    self.selectedValues.formIntersection(self.values.map(\.id))
                    if self.showingValues, self.selectedValues.count == 1, let id = self.selectedValues.first, let row = self.values.first(where: { $0.id == id }) {
                        self.draft = Self.draft(for: row.finding, source: .panel)
                    }
                    self.notice = told?(revised)
                    switch after {
                    case .copy: self.copy()
                    case .save: self.save()
                    case nil: break
                    }
                case .failure(let error):
                    self.state = .failed(name: current.name, source: current.source, code: Self.code(for: error))
                }
            }
        }
    }

    func copy() {
        guard cleared(then: .copy), case .finished(var done) = state else { return }
        guard let text = String(data: done.result.output, encoding: .utf8) else { return }
        board.clearContents()
        board.setString(text, forType: .string)
        copiedChangeCount = board.changeCount
        done.copied = true
        state = .finished(done)
        let ticket = generation
        copyResets += 1
        let reset = copyResets
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard ticket == generation, reset == copyResets, case .finished(var current) = state else { return }
            current.copied = false
            state = .finished(current)
        }
    }

    func save() {
        guard cleared(then: .save), case .finished(var done) = state else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "scrubbed.\(Self.fileExtension(done.result.format))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PrivateFile.write(done.result.output, to: url)
            done.savedAs = url.lastPathComponent
            failedSave = false
        } catch {
            done.savedAs = nil
            failedSave = true
        }
        state = .finished(done)
    }

    /// Takes back what Scrub put on the clipboard, if nothing has replaced it since.
    func releaseClipboard() {
        guard let ours = copiedChangeCount else { return }
        copiedChangeCount = nil
        if board.changeCount == ours { board.clearContents() }
    }

    private func stop() {
        generation += 1
        work?.cancel()
        work = nil
        reviewing = false
        afterReview = nil
        applyingReview = false
        afterRewrite = nil
        pick = Pick()
        history = []
        position = 0
        notice = nil
        draft = nil
        showingValues = false
        valueSearch = ""
        valueKind = nil
        valueFilter = .all
        selectedValues = []
        selectionAnchor = nil
        valueCursor = nil
        values = []
        reveal = nil
        placing = nil
    }

    private func fail(_ name: String, _ source: Source, _ code: String) {
        stop()
        state = .failed(name: name, source: source, code: code)
    }

    private func start(_ name: String, _ source: Source, _ data: Data) {
        stop()
        guard data.count <= Self.maxBytes else { return fail(name, source, "too_large") }
        let ticket = generation
        state = .processing(name: name, source: source, stage: .starting, done: 0, total: 0)
        let scrub = self.scrub
        work = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result {
                try scrub(data, name) { stage, done, total in
                    Task { @MainActor in
                        guard let self, self.generation == ticket, case .processing = self.state else { return }
                        self.state = .processing(name: name, source: source, stage: stage, done: done, total: total)
                    }
                }
            }
            let rows = (try? outcome.get()).map { ValueRow.rows(of: $0, choices: $0.choices, edits: Edits(), reviewed: false) }
            await MainActor.run {
                guard let self, self.generation == ticket else { return }
                switch outcome {
                case .success(let result):
                    self.state = .finished(Finished(name: name, source: source, result: result, choices: result.choices))
                    self.values = rows ?? []
                    self.history = [Step(choices: result.choices, marks: Marks(), reviewed: false, name: "")]
                    self.position = 0
                    // The first selection in a large file then answers at once.
                    Task.detached(priority: .utility) { result.prepareMarking() }
                case .failure(let error): self.state = .failed(name: name, source: source, code: Self.code(for: error))
                }
            }
        }
    }

    private static func code(for error: Error) -> String {
        switch error as? ScrubError {
        case .cancelled: "cancelled"
        case .unsupported(let code): code
        case nil: "unexpected"
        }
    }

    private static func fileExtension(_ format: String) -> String {
        switch format {
        case "json": "json"
        case "xml": "xml"
        case "csv": "csv"
        default: "txt"
        }
    }

}
