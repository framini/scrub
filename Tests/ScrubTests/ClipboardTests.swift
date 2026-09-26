import AppKit
@testable import Scrub
import Testing

@MainActor
private func finishedModel() async throws -> (AppModel, NSPasteboard) {
    let board = NSPasteboard(name: NSPasteboard.Name("scrub-tests-\(UUID().uuidString)"))
    board.clearContents()
    board.setString("Call Maria Gonzalez on +1 (415) 555-0132.", forType: .string)
    let model = AppModel(board: board)
    model.paste()
    for _ in 0..<200 {
        if case .finished = model.state { return (model, board) }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("paste never finished")
    throw CancellationError()
}

@MainActor
@Test func startingOverTakesBackTheCopiedResult() async throws {
    let (model, board) = try await finishedModel()
    model.copy()
    #expect(board.string(forType: .string)?.contains("Maria") == false)
    model.clear()
    #expect(board.string(forType: .string) == nil)
}

@MainActor
@Test func startingOverTakesBackACopiedSelection() async throws {
    let (model, board) = try await finishedModel()
    model.copyCommand(sendCopy: {
        board.clearContents()
        return board.setString("part of the result", forType: .string)
    })
    #expect(board.string(forType: .string) == "part of the result")
    model.clear()
    #expect(board.string(forType: .string) == nil)
}

@MainActor
@Test func withNoSelectionCopyTakesTheWholeResult() async throws {
    let (model, board) = try await finishedModel()
    model.copyCommand(sendCopy: { true })
    guard case .finished(let done) = model.state else { Issue.record("not finished"); return }
    #expect(board.string(forType: .string) == String(decoding: done.result.output, as: UTF8.self))
}

@MainActor
@Test func aLaterCopyElsewhereIsLeftAlone() async throws {
    let (model, board) = try await finishedModel()
    model.copyCommand(sendCopy: {
        board.clearContents()
        return board.setString("part of the result", forType: .string)
    })
    board.clearContents()
    board.setString("copied in another app", forType: .string)
    model.clear()
    #expect(board.string(forType: .string) == "copied in another app")
}
