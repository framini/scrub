import AppKit
@testable import Scrub
import ScrubCore
import Testing

/// A value selected in the preview is replaced everywhere in what Copy
/// writes, a stand-in selected there can be kept as its original, and both
/// pass the same export gate as everything else.
@MainActor
private func finished(_ text: String) async throws -> (AppModel, NSPasteboard) {
    let board = NSPasteboard(name: NSPasteboard.Name("scrub-marking-\(UUID().uuidString)"))
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

/// Checks what Scrub asks about first, so Copy is free to go.
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

private let handover = "Handover for Odalys Ferriter: the parcel waits at the Quillmere depot. QUILLMERE closes at six, and Quillmere's side gate is the one to use."

@MainActor
private func preview(_ done: Finished) throws -> (String, [Mark]) {
    guard case .text(let text, let marks, _) = done.result.preview else { throw CancellationError() }
    return (text, marks)
}

@MainActor
@Test func aSelectedValueIsReplacedEverywhereInWhatIsCopied() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let (text, marks) = try preview(done)
    let at = (text as NSString).range(of: "Quillmere")
    try #require(at.location != NSNotFound, "Scrub must have missed the depot: \(text)")
    // Part of the word is selected; the whole word is what is marked.
    model.select(PreviewSelection(text: text, marks: marks, range: (at.location + 1)..<(at.location + 5)))
    #expect(model.pick.missed == ["Quillmere"])
    model.markKind = "LOCATION"
    model.applySelection()
    // Copied at once, it waits for the mark to be written in.
    board.clearContents()
    model.copy()
    #expect(board.string(forType: .string) == nil)
    try await settled(model)
    let copied = try #require(board.string(forType: .string))
    #expect(!copied.lowercased().contains("quillmere") && !copied.contains("Ferriter"), "\(copied)")
    guard case .finished(let after) = model.state else { Issue.record("not finished"); return }
    #expect(after.marks.entries.map(\.text) == ["Quillmere"] && after.result.byHand.first?.places.count == 3)
}

@MainActor
@Test func eachMarkedPlaceCanBeUndoneOnItsOwn() async throws {
    let (model, board) = try await finished(handover)
    _ = try await reviewed(model)
    model.mark(["Quillmere"], as: "LOCATION")
    try await settled(model)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    let marked = try #require(done.result.byHand.first)
    var choices = done.choices
    choices.set(try #require(marked.places.last), leave: true)
    model.review()
    model.finishReview(choices)
    try await settled(model)
    model.copy()
    let copied = try #require(board.string(forType: .string))
    #expect(copied.components(separatedBy: "Quillmere").count == 2 && !copied.contains("QUILLMERE"), "\(copied)")
}

@MainActor
@Test func aClickOnAStandInKeepsItsOriginalEverywhere() async throws {
    let (model, board) = try await finished(handover)
    let done = try await reviewed(model)
    let customer = try #require(done.result.findings.first { $0.original == "Odalys Ferriter" })
    let (text, marks) = try preview(done)
    let at = (text as NSString).range(of: customer.standIn)
    model.select(PreviewSelection(text: text, marks: marks, range: (at.location + 1)..<(at.location + 1)))
    #expect(model.pick.replaced.contains { $0.id == customer.id } && model.pick.missed.isEmpty)
    model.applySelection()
    try await settled(model)
    model.copy()
    let copied = try #require(board.string(forType: .string))
    #expect(copied.contains("Odalys Ferriter") && !copied.contains(customer.standIn), "\(copied)")
    // Selected again where it now stands as written, it is replaced again.
    guard case .finished(let kept) = model.state else { Issue.record("not finished"); return }
    let (shown, keptMarks) = try preview(kept)
    let back = (shown as NSString).range(of: "Odalys Ferriter")
    model.select(PreviewSelection(text: shown, marks: keptMarks, range: back.location..<NSMaxRange(back)))
    #expect(model.pick.missed == ["Odalys Ferriter"])
    model.markKind = "PERSON"
    model.applySelection()
    try await settled(model)
    model.copy()
    #expect(board.string(forType: .string).map { !$0.contains("Ferriter") } == true)
}

/// Marking changes what is written, never whether it may leave: what Scrub
/// asks about still waits to be checked.
@MainActor
@Test func markingLeavesTheExportGateAsItWas() async throws {
    let note = "Ms Odalys Ferriter called about the refund. Brightwater from billing called back, and Brightwater wants the invoice. The Quillmere depot has it."
    let (model, board) = try await finished(note)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    try #require(done.needsReview, "the note must hold something to check")
    model.mark(["Quillmere"], as: "LOCATION")
    try await settled(model)
    board.clearContents()
    model.copy()
    #expect(model.reviewing && board.string(forType: .string) == nil)
    guard case .finished(let marked) = model.state else { Issue.record("not finished"); return }
    #expect(!marked.mayExport && !marked.result.byHand.isEmpty)
    model.finishReview(marked.choices)
    try await settled(model)
    let copied = try #require(board.string(forType: .string))
    #expect(!copied.contains("Quillmere"), "\(copied)")
}

@MainActor
@Test func theKindIsGuessedForEachSelection() async throws {
    let (model, _) = try await finished("Courier note: call the depot at (415) 867-2290 or write to dispatch at the Quillmere office, ref GRV-88213.")
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    let (text, marks) = try preview(done)
    let code = (text as NSString).range(of: "GRV-88213")
    if code.location != NSNotFound {
        model.select(PreviewSelection(text: text, marks: marks, range: code.location..<NSMaxRange(code)))
        #expect(model.markKind == "ID_NUMBER")
    }
    model.select(nil)
    #expect(model.pick.isEmpty)
}

/// A mark is one ⌘Z away from gone, and one ⇧⌘Z away from back: what Copy
/// writes follows each step, and the bar under the preview says what happened.
@MainActor
@Test func aMarkCanBeUndoneAndRedone() async throws {
    let (model, board) = try await finished(handover)
    _ = try await reviewed(model)
    model.copy()
    let before = try #require(board.string(forType: .string))
    try #require(before.contains("Quillmere"), "Scrub must have missed the depot: \(before)")
    #expect(!model.canUndo && !model.canRedo)
    model.mark(["Quillmere"], as: "LOCATION")
    try await settled(model)
    #expect(model.notice?.text == "Replaced “Quillmere” as a place in 3 places" && model.notice?.undone == false, "\(String(describing: model.notice))")
    #expect(model.undoTitle == "Undo Replace “Quillmere”")
    model.copy()
    let marked = try #require(board.string(forType: .string))
    #expect(!marked.lowercased().contains("quillmere"))
    model.undo()
    try await settled(model)
    #expect(model.notice?.undone == true && model.redoTitle == "Redo Replace “Quillmere”" && !model.canUndo)
    model.copy()
    #expect(board.string(forType: .string) == before)
    guard case .finished(let undone) = model.state else { Issue.record("not finished"); return }
    #expect(undone.marks.isEmpty && undone.result.byHand.isEmpty)
    model.redo()
    try await settled(model)
    model.copy()
    #expect(board.string(forType: .string) == marked && !model.canRedo)
    // A new change after an undo drops what was undone.
    model.undo()
    try await settled(model)
    model.mark(["QUILLMERE"], as: "LOCATION")
    try await settled(model)
    #expect(!model.canRedo && model.canUndo)
}

/// A mark the person made is taken off from the stand-in itself, and the
/// bar says it is theirs.
@MainActor
@Test func aMarkIsTakenOffFromItsStandIn() async throws {
    let (model, board) = try await finished(handover)
    _ = try await reviewed(model)
    model.copy()
    let before = try #require(board.string(forType: .string))
    model.mark(["Quillmere"], as: "LOCATION")
    try await settled(model)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    let (text, marks) = try preview(done)
    let mine = try #require(marks.first { $0.byHand })
    model.select(PreviewSelection(text: text, marks: marks, range: mine.range.lowerBound..<mine.range.lowerBound))
    #expect(!model.pick.marked.isEmpty && model.pick.replaced.isEmpty && model.notice == nil)
    model.applySelection()
    try await settled(model)
    model.copy()
    #expect(board.string(forType: .string) == before)
    #expect(model.notice?.text.hasPrefix("Took the mark off “Quillmere”") == true && model.undoTitle == "Undo Remove Mark on “Quillmere”")
}

/// Undoing the review's choices asks for the review again before anything
/// leaves; undoing a mark made after it does not.
@MainActor
@Test func undoingTheReviewClosesTheGateAgain() async throws {
    let note = "Ms Odalys Ferriter called about the refund. Brightwater from billing called back, and Brightwater wants the invoice. The Quillmere depot has it."
    let (model, board) = try await finished(note)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    try #require(done.needsReview, "the note must hold something to check")
    var choices = done.choices
    for finding in done.result.uncertain { choices.set(finding, leave: !choices.leaves(try #require(finding.places.first), of: finding)) }
    model.review()
    model.finishReview(choices)
    try await settled(model)
    model.mark(["Quillmere"], as: "LOCATION")
    try await settled(model)
    model.undo()
    try await settled(model)
    guard case .finished(let unmarked) = model.state else { Issue.record("not finished"); return }
    #expect(unmarked.mayExport && unmarked.choices == choices)
    #expect(model.undoTitle == "Undo Review Choices")
    model.undo()
    try await settled(model)
    guard case .finished(let unreviewed) = model.state else { Issue.record("not finished"); return }
    #expect(!unreviewed.mayExport && unreviewed.choices == done.choices)
    board.clearContents()
    model.copy()
    #expect(model.reviewing && board.string(forType: .string) == nil)
}
