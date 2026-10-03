import Foundation
@testable import ScrubCore
import Testing

/// How the context model's overlapping windows are joined: the first window
/// to read a piece decides it. (Taking the window that sees most around each
/// piece read generated text better but real court text worse, so it was not kept.)
struct ContextWindowTests {
    /// Three windows of 6 pieces over 14, each 4 on from the last (so 2 shared),
    /// reading every piece as its window's number: a shared piece keeps the
    /// earlier window's reading.
    @Test func eachPieceTakesTheFirstWindowThatReadsIt() throws {
        let model = try #require(ContextModel.shared)
        let pieces = (0..<14).map { PieceTokenizer.Piece(id: 5, range: $0 * 2..<($0 * 2 + 1)) }
        let windows = [0, 4, 8].map { first in (first: first, ids: [Int32](repeating: 5, count: 8)) }
        let predictions: [[ContextModel.Decision]?] = (0..<3).map { window in
            Array(repeating: ContextModel.Decision(label: window, none: 0), count: 8)
        }
        let labels = model.labelled(pieces, windows: windows, predictions: predictions).map { $0?.label }
        #expect(labels == [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2])
    }

    /// A window the gate left unread leaves its pieces to the windows beside it.
    @Test func anUnreadWindowDecidesNothing() throws {
        let model = try #require(ContextModel.shared)
        let pieces = (0..<10).map { PieceTokenizer.Piece(id: 5, range: $0..<($0 + 1)) }
        let windows = [0, 4].map { first in (first: first, ids: [Int32](repeating: 5, count: 8)) }
        let labels = model.labelled(pieces, windows: windows, predictions: [nil, Array(repeating: ContextModel.Decision(label: 3, none: 0), count: 8)]).map { $0?.label }
        #expect(labels == [nil, nil, nil, nil, 3, 3, 3, 3, 3, 3])
    }
}
