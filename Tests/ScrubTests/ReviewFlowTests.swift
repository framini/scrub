import AppKit
@testable import Scrub
import ScrubCore
import Testing

/// Copy and Save wait for the uncertain findings to be checked, and write
/// what the person chose: a finding left as written is the original wherever
/// it stood, every other stand-in as before.
@MainActor
private func finished(_ text: String) async throws -> (AppModel, NSPasteboard) {
    let board = NSPasteboard(name: NSPasteboard.Name("scrub-review-\(UUID().uuidString)"))
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

private let note = "Ms Odalys Ferriter called about the refund. Brightwater from billing called back, and Brightwater wants the invoice."

@MainActor
@Test func copyAsksAboutUncertainFindingsFirst() async throws {
    let (model, board) = try await finished(note)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    let place = try #require(done.result.uncertain.first { $0.original == "Brightwater" })
    board.clearContents()
    model.copy()
    #expect(model.reviewing && board.string(forType: .string) == nil)

    model.finishReview(Choices(left: [place.id]))
    try await settled(model)
    let copied = try #require(board.string(forType: .string))
    #expect(copied.components(separatedBy: "Brightwater").count == 3 && !copied.contains("Ferriter"), "\(copied)")
    guard case .finished(let after) = model.state else { Issue.record("not finished"); return }
    #expect(after.reviewed && after.choices.left == [place.id] && !model.reviewing)
}

@MainActor
@Test func keepingEverythingCopiesTheScrubAsMade() async throws {
    let (model, board) = try await finished(note)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    model.copy()
    #expect(model.reviewing)
    model.finishReview(Choices(left: []))
    try await settled(model)
    #expect(board.string(forType: .string) == String(decoding: done.result.output, as: UTF8.self))
    // Checked once, Copy no longer asks.
    board.clearContents()
    model.copy()
    #expect(!model.reviewing && board.string(forType: .string) != nil)
}

@MainActor
@Test func cancellingTheReviewCopiesNothing() async throws {
    let (model, board) = try await finished(note)
    board.clearContents()
    model.copy()
    model.cancelReview()
    #expect(!model.reviewing && board.string(forType: .string) == nil)
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    #expect(done.needsReview)
}

/// A suspect the final check found starts left as written, so Copy asks about
/// it; leaving it copies the scrub as made, and replacing it copies its stand-in.
@MainActor
@Test func aSuspectStartsLeftAsWrittenAndCanBeReplaced() async throws {
    let (model, board) = try await finished("Odalys Ferriter asked us to fix her blog at https://odalysf.blog.example/about today.")
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    let suspect = try #require(done.result.uncertain.first { $0.suspected && $0.original == "odalysf" })
    #expect(done.choices.left == [suspect.id] && done.needsReview)

    board.clearContents()
    model.copy()
    #expect(model.reviewing)
    model.finishReview(done.choices)
    try await settled(model)
    #expect(board.string(forType: .string) == String(decoding: done.result.output, as: UTF8.self))

    model.finishReview(Choices(left: []))
    try await settled(model)
    guard case .finished(let after) = model.state else { Issue.record("not finished"); return }
    let output = String(decoding: after.result.output, as: UTF8.self)
    #expect(!output.contains("odalysf") && output.contains("https://\(suspect.standIn).blog.example/about today"), "\(output)")
    #expect(after.choices.left.isEmpty && after.result.leftAsWritten.isEmpty)
}
