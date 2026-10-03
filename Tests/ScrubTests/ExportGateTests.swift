import AppKit
@testable import Scrub
@testable import ScrubCore
import Testing

/// Nothing leaves the app while uncertain findings wait to be checked: Copy,
/// ⌘C on a selection, and Save all open the review first, through one gate.
@MainActor
private func finished(_ text: String, scrub: AppModel.Scrub? = nil) async throws -> (AppModel, NSPasteboard) {
    let board = NSPasteboard(name: NSPasteboard.Name("scrub-gate-\(UUID().uuidString)"))
    board.clearContents()
    board.setString(text, forType: .string)
    let model = scrub.map { AppModel(board: board, scrub: $0) } ?? AppModel(board: board)
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

private let note = "Ms Odalys Ferriter called about the refund. Brightwater from billing called back, and Brightwater wants the invoice."

@MainActor
@Test func aSelectionWaitsForTheReviewLikeTheWholeResult() async throws {
    let (model, board) = try await finished(note)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    #expect(done.needsReview && !done.mayExport, "the note must hold something to check")
    board.clearContents()
    var sent = false
    model.copyCommand(sendCopy: {
        sent = true
        board.clearContents()
        return board.setString("Brightwater from billing", forType: .string)
    })
    #expect(!sent && board.string(forType: .string) == nil && model.reviewing)

    model.finishReview(Choices(left: []))
    try await settled(model)
    #expect(board.string(forType: .string) == String(decoding: done.result.output, as: UTF8.self))
    guard case .finished(let after) = model.state else { Issue.record("not finished"); return }
    #expect(after.mayExport)

    // Checked once, a selection copies as it is.
    model.copyCommand(sendCopy: {
        sent = true
        board.clearContents()
        return board.setString("part of the result", forType: .string)
    })
    #expect(sent && board.string(forType: .string) == "part of the result")
}

@MainActor
@Test func everyWayOutOpensTheReviewFirst() async throws {
    let (model, board) = try await finished(note)
    board.clearContents()
    for exit in [{ model.copy() }, { model.copyCommand(sendCopy: { Issue.record("a selection was copied"); return true }) }, { model.save() }] {
        exit()
        #expect(model.reviewing && board.string(forType: .string) == nil)
        model.cancelReview()
    }
    // While the review is open, a second ⌘C neither copies nor changes what follows it.
    model.save()
    model.copyCommand(sendCopy: { Issue.record("a selection was copied"); return true })
    #expect(model.reviewing && board.string(forType: .string) == nil)
    model.cancelReview()
}

/// A model that fails its checksum leaves the scrub without it; the result says so.
@MainActor
@Test func aMissingModelIsShownAsReducedCoverage() async throws {
    let (full, _) = try await finished(note)
    guard case .finished(let complete) = full.state else { Issue.record("not finished"); return }
    #expect(!complete.result.coverage.isReduced)

    let (model, _) = try await finished(note, scrub: { data, name, progress in
        try Coverage.$withheld.withValue([.contextModel]) { try Scrubber.scrub(data, name: name, progress: progress) }
    })
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    #expect(done.result.coverage.missing == [.contextModel])
    let message = Copy.reducedCoverage(done.result.coverage.missing)
    #expect(message.hasPrefix("The context model is missing or damaged") && message.hasSuffix("restore it."), "\(message)")
    #expect(Copy.reducedCoverage([.nameModel, .contextModel]).hasPrefix("The name model and the context model are missing"))

    // Taking findings back keeps the status.
    model.finishReview(Choices(left: []))
    try await settled(model)
    guard case .finished(let after) = model.state else { Issue.record("not finished"); return }
    #expect(after.result.coverage.missing == [.contextModel])
}

/// The preview can always be selected and read; what a selection does waits
/// for the review like everything else that leaves the app: its menu's
/// Copy, a drag out of the window and a service write nothing until then.
@MainActor
@Test func aSelectionCanBeMadeButNotTakenBeforeTheReview() async throws {
    let (model, board) = try await finished(note)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    #expect(!done.mayExport, "the note must hold something to check")
    board.clearContents()
    let output = String(decoding: done.result.output, as: UTF8.self)
    let view = PreviewTextView()
    view.isEditable = false
    view.isSelectable = true
    view.textStorage?.setAttributedString(ResultView.styled(output, [], font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
    view.allowsExport = done.mayExport
    view.blocked = { model.selectionBlocked(copying: $0) }
    #expect(view.isSelectable && !view.isEditable)
    view.selectAll(nil)
    #expect(view.selectedRange().length == (output as NSString).length)

    // A drag writes to a pasteboard of its own: nothing, and the review opens.
    let drag = NSPasteboard(name: NSPasteboard.Name("scrub-drag-\(UUID().uuidString)"))
    drag.clearContents()
    #expect(!view.writeSelection(to: drag, types: view.writablePasteboardTypes))
    #expect(drag.string(forType: .string) == nil && model.reviewing)
    model.cancelReview()
    // Services find no text to take.
    for type in view.writablePasteboardTypes { #expect(view.validRequestor(forSendType: type, returnType: nil) == nil) }
    // The context menu's Copy writes nothing anywhere and asks first, as ⌘C does.
    let general = NSPasteboard.general.changeCount
    view.copy(nil)
    #expect(NSPasteboard.general.changeCount == general && model.reviewing)

    model.finishReview(Choices(left: []))
    try await settled(model)
    #expect(board.string(forType: .string) == output)
    guard case .finished(let after) = model.state else { Issue.record("not finished"); return }
    #expect(after.mayExport)

    // Checked once, the selection leaves as it is, and nothing else is asked.
    view.allowsExport = after.mayExport
    drag.clearContents()
    #expect(view.writeSelection(to: drag, types: view.writablePasteboardTypes))
    #expect(drag.string(forType: .string) == output && !model.reviewing)
    #expect(view.writablePasteboardTypes.contains { view.validRequestor(forSendType: $0, returnType: nil) != nil })
}

/// Asking twice opens one review; a blocked drag adds no copy after it.
@MainActor
@Test func aBlockedDragOpensTheReviewWithoutACopy() async throws {
    let (model, board) = try await finished(note)
    board.clearContents()
    model.selectionBlocked(copying: false)
    model.selectionBlocked(copying: true)
    #expect(model.reviewing)
    model.finishReview(Choices(left: []))
    try await settled(model)
    #expect(board.string(forType: .string) == nil, "a drag asks, but copies nothing afterwards")
}
