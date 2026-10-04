import AppKit
@testable import Scrub
import ScrubCore
import Testing

/// A click on a stand-in opens its editor, which changes the value's kind or
/// writes a replacement typed for it; the Values panel lists every value, to
/// search, filter and change many at once. Both pass the same export gate
/// and undo history as every other change.
@MainActor
private func finished(_ text: String) async throws -> (AppModel, NSPasteboard) {
    let board = NSPasteboard(name: NSPasteboard.Name("scrub-editing-\(UUID().uuidString)"))
    board.clearContents()
    board.setString(text, forType: .string)
    let model = AppModel(board: board)
    model.paste()
    for _ in 0..<400 {
        if case .finished = model.state { return (model, board) }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("paste never finished")
    throw CancellationError()
}

@MainActor
private func settled(_ model: AppModel) async throws {
    for _ in 0..<400 where model.applyingReview { try await Task.sleep(for: .milliseconds(25)) }
}

@MainActor
private func reviewed(_ model: AppModel) async throws -> Finished {
    guard case .finished(let done) = model.state else { throw CancellationError() }
    if done.needsReview {
        model.finishReview(done.choices)
        try await settled(model)
    }
    guard case .finished(let after) = model.state else { throw CancellationError() }
    return after
}

@MainActor
private func copied(_ model: AppModel, _ board: NSPasteboard) throws -> String {
    board.clearContents()
    model.copy()
    return try #require(board.string(forType: .string))
}

private let handover = "Handover for Odalys Ferriter (odalys.ferriter@kestrel.example). Ms Ferriter asked us to call before noon, and Odalys said the side gate is open."

/// Clicks inside the first place of `standIn` in the text preview.
@MainActor
private func click(_ standIn: String, in done: Finished, _ model: AppModel) throws {
    guard case .text(let text, let marks, _) = done.result.preview else { throw CancellationError() }
    let at = (text as NSString).range(of: standIn)
    try #require(at.location != NSNotFound, "\(standIn) not in \(text)")
    model.select(PreviewSelection(text: text, marks: marks, range: (at.location + 1)..<(at.location + 1)))
}

@MainActor
@Test func theEditorAppliesATypedReplacementEverywhere() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let before = try copied(model, board)
    let customer = try #require(done.result.findings.first { $0.original == "Odalys Ferriter" })
    try click(customer.standIn, in: done, model)
    let draft = try #require(model.draft, "a click on a stand-in opens its editor")
    #expect(draft.original == "Odalys Ferriter" && draft.text == customer.standIn && draft.kind == customer.entity && !draft.changed)
    model.draft?.text = "Jane Roe"
    model.applyDraft()
    // Copied at once, it waits for the edit to be written in.
    board.clearContents()
    model.copy()
    #expect(board.string(forType: .string) == nil && !model.selectionMayLeave)
    try await settled(model)
    let after = try #require(board.string(forType: .string))
    #expect(after.contains("Handover for Jane Roe") && after.contains("Ms Roe") && !after.contains("Ferriter"), "\(after)")
    #expect(model.notice?.text.hasPrefix("Replaced “Odalys Ferriter” with “Jane Roe”") == true, "\(String(describing: model.notice))")
    #expect(model.undoTitle == "Undo Replace “Odalys Ferriter” with “Jane Roe”" && model.draft == nil)
    // Undo writes the result as it was, and redo the same bytes again.
    model.undo()
    try await settled(model)
    #expect(try copied(model, board) == before)
    model.redo()
    try await settled(model)
    #expect(try copied(model, board) == after)
}

@MainActor
@Test func escClosesTheEditorAndChangesNothing() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let before = try copied(model, board)
    let customer = try #require(done.result.findings.first { $0.original == "Odalys Ferriter" })
    try click(customer.standIn, in: done, model)
    model.draft?.text = "Jane Roe"
    model.draft?.kind = "EMPLOYER"
    model.cancelDraft()
    #expect(model.draft == nil && model.pick.isEmpty && !model.applyingReview && !model.canUndo)
    #expect(try copied(model, board) == before)
}

@MainActor
@Test func anUnsafeReplacementIsRefusedInTheEditor() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let before = try copied(model, board)
    let customer = try #require(done.result.findings.first { $0.original == "Odalys Ferriter" })
    try click(customer.standIn, in: done, model)
    model.draft?.text = "Odalys Ferriter Jr"
    model.applyDraft()
    #expect(model.draft?.refusal == .original && !model.applyingReview && !model.canUndo)
    #expect(Copy.refusal(.original, original: "Odalys Ferriter") == "That still holds “Odalys Ferriter”")
    model.draft?.text = ""
    model.applyDraft()
    #expect(model.draft?.refusal == .empty)
    #expect(try copied(model, board) == before)
}

@MainActor
@Test func theEditorChangesAKind() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let customer = try #require(done.result.findings.first { $0.original == "Odalys Ferriter" })
    try click(customer.standIn, in: done, model)
    model.draft?.kind = "USERNAME"
    model.applyDraft()
    try await settled(model)
    #expect(model.undoTitle == "Undo Change “Odalys Ferriter” to Username", "\(model.undoTitle)")
    guard case .finished(let changed) = model.state else { Issue.record("not finished"); return }
    let revised = changed.result.revised(customer)
    #expect(revised.entity == "USERNAME" && !revised.standIn.contains(" ") && revised.standIn != customer.standIn, "\(revised.standIn)")
    let after = try copied(model, board)
    #expect(after.contains(revised.standIn) && !after.contains(customer.standIn) && !after.contains("Ferriter"), "\(after)")
}

@MainActor
@Test func thePanelFiltersAndSearchesItsRows() async throws {
    let (model, _) = try await finished(handover)
    _ = try await reviewed(model)
    model.toggleValues()
    #expect(model.showingValues && !model.values.isEmpty)
    let all = model.visibleValues.count
    #expect(all == model.values.count)
    // A search over originals and stand-ins, in any case and without accents.
    model.valueSearch = "FÉRR"
    #expect(!model.visibleValues.isEmpty && model.visibleValues.allSatisfy { $0.search.contains("ferr") })
    let customer = try #require(model.values.first { $0.finding.original == "Odalys Ferriter" })
    model.valueSearch = String(customer.finding.standIn.dropFirst(1).prefix(4))
    #expect(model.visibleValues.contains { $0.id == customer.id })
    model.valueSearch = ""
    model.valueKind = "Email"
    #expect(!model.visibleValues.isEmpty && model.visibleValues.allSatisfy { $0.finding.entity == "EMAIL_ADDRESS" })
    model.valueKind = nil
    // Nothing is the person's own until they change something.
    model.valueFilter = .yours
    #expect(model.visibleValues.isEmpty)
    model.valueFilter = .status(.replaced)
    #expect(!model.visibleValues.isEmpty && model.visibleValues.allSatisfy { $0.status == .replaced })
    model.valueFilter = .all
    // A row selected alone opens its editor, and the preview is asked to show it.
    model.selectValue(customer.id)
    #expect(model.draft?.source == .panel && model.draft?.original == "Odalys Ferriter" && model.reveal?.original == "Odalys Ferriter")
    guard case .finished(let done) = model.state, case .text(let text, let marks, _) = done.result.preview, let reveal = model.reveal else { Issue.record("no text preview"); return }
    let place = try #require(PreviewText.place(of: reveal, in: text, marks: marks))
    #expect(PreviewText.substring(text, place) == customer.finding.standIn)
}

@MainActor
@Test func thePanelChangesManyKindsAtOnceAndKeepsThem() async throws {
    let (model, board) = try await finished(handover)
    _ = try await reviewed(model)
    model.toggleValues()
    let customer = try #require(model.values.first { $0.finding.original == "Odalys Ferriter" })
    let email = try #require(model.values.first { $0.finding.entity == "EMAIL_ADDRESS" })
    model.selectValue(customer.id)
    model.selectValue(email.id, toggling: true)
    #expect(model.selectedValues == [customer.id, email.id] && model.draft == nil)
    model.changeKind(of: model.selectedValues, to: "ID_NUMBER")
    #expect(model.applyingReview && !model.selectionMayLeave)
    try await settled(model)
    #expect(model.undoTitle == "Undo Change “Odalys Ferriter” and 1 more to ID", "\(model.undoTitle)")
    let changed = model.values.filter { [customer.id, email.id].contains($0.id) }
    #expect(changed.count == 2 && changed.allSatisfy { $0.finding.entity == "ID_NUMBER" && $0.edited && $0.yours })
    model.valueFilter = .yours
    #expect(Set(model.visibleValues.map(\.id)) == [customer.id, email.id])
    model.valueFilter = .all
    // Kept, both are written as they were, and each shows so.
    model.keepValues(model.selectedValues)
    try await settled(model)
    let after = try copied(model, board)
    #expect(after.contains("Odalys Ferriter") && after.contains("odalys.ferriter@kestrel.example"), "\(after)")
    #expect(model.values.filter { [customer.id, email.id].contains($0.id) }.allSatisfy { $0.status == .left })
    // Replaced again, they take their changed stand-ins back.
    model.replaceValuesAgain([customer.id, email.id])
    try await settled(model)
    #expect(!(try copied(model, board)).contains("Ferriter"))
    model.undo()
    try await settled(model)
    #expect(try copied(model, board) == after)
}

/// Undo and redo walk edits as they walk marks: each step's bytes come back exactly.
@MainActor
@Test func editsAndMarksUndoInOrder() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let start = try copied(model, board)
    model.mark(["side gate"], as: "LOCATION")
    try await settled(model)
    let marked = try copied(model, board)
    let customer = try #require(done.result.findings.first { $0.original == "Odalys Ferriter" })
    guard case .finished(let current) = model.state else { Issue.record("not finished"); return }
    try click(current.result.revised(customer).standIn, in: current, model)
    model.draft?.text = "Jane Roe"
    model.applyDraft()
    try await settled(model)
    let edited = try copied(model, board)
    #expect(edited != marked && !edited.contains("side gate") && edited.contains("Jane Roe"))
    model.undo()
    try await settled(model)
    #expect(try copied(model, board) == marked)
    model.undo()
    try await settled(model)
    #expect(try copied(model, board) == start)
    model.redo()
    model.redo()
    try await settled(model)
    #expect(try copied(model, board) == edited)
}

@MainActor
@Test func theArrowKeysWalkThePanelsRows() async throws {
    let (model, _) = try await finished(handover)
    _ = try await reviewed(model)
    model.toggleValues()
    let rows = model.visibleValues
    try #require(rows.count >= 3)
    // ↓ with nothing selected starts at the first row, and opens its editor as a click would.
    model.moveValueSelection(by: 1)
    #expect(model.selectedValues == [rows[0].id] && model.valueCursor == rows[0].id && model.draft?.original == rows[0].finding.original)
    model.moveValueSelection(by: 1)
    #expect(model.selectedValues == [rows[1].id] && model.reveal?.original == rows[1].finding.original)
    model.moveValueSelection(by: -1)
    #expect(model.selectedValues == [rows[0].id])
    // It stops at either end.
    model.moveValueSelection(by: -1)
    #expect(model.selectedValues == [rows[0].id])
    // ⇧ grows the selection from where it started, and shrinks it walking back.
    model.moveValueSelection(by: 1, extending: true)
    model.moveValueSelection(by: 1, extending: true)
    #expect(model.selectedValues == Set(rows[0...2].map(\.id)) && model.draft == nil)
    model.moveValueSelection(by: -1, extending: true)
    #expect(model.selectedValues == Set(rows[0...1].map(\.id)))
    // ⌘ goes to the last row and the first.
    model.moveValueSelection(by: 1, toEnd: true)
    #expect(model.selectedValues == [rows[rows.count - 1].id])
    model.moveValueSelection(by: -1, toEnd: true)
    #expect(model.selectedValues == [rows[0].id])
    // A click moves the cursor too; ↑ from there is the row above it.
    model.selectValue(rows[2].id)
    model.moveValueSelection(by: -1)
    #expect(model.selectedValues == [rows[1].id])
    // Only the rows the filters leave are walked.
    model.valueKind = "Email"
    let emails = model.visibleValues
    try #require(!emails.isEmpty)
    model.moveValueSelection(by: 1)
    #expect(model.selectedValues == [emails[0].id])
    // Hiding the panel forgets where it was; ↑ then starts at the last row.
    model.toggleValues()
    model.toggleValues()
    model.valueKind = nil
    #expect(model.valueCursor == nil)
    model.moveValueSelection(by: -1)
    #expect(model.selectedValues == [rows[rows.count - 1].id])
}
