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
    var reviewed = false
    var needsReview: Bool { !reviewed && !result.uncertain.isEmpty }
    /// Whether anything of the result may leave the app yet: whole, as a
    /// selection, or saved. Every way out asks this one question (see `AppModel.cleared`).
    var mayExport: Bool { !needsReview }
}

enum Shortcut { case copy, save }

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
    /// The preview can only be selected, and so dragged, shared or sent to a
    /// service, once this gate is clear (`Finished.mayExport`).
    private func cleared(then shortcut: Shortcut) -> Bool {
        guard case .finished(let done) = state else { return false }
        if done.mayExport { return true }
        if !reviewing { review(then: shortcut) }
        return false
    }

    /// ⌘C copies a selection when the focused view has one, and otherwise the
    /// whole result. A responder with nothing selected leaves the pasteboard
    /// untouched, which is how the two cases are told apart. While the result
    /// waits for review nothing can be selected, and ⌘C asks first.
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
        guard case .finished(let done) = state else { return }
        reviewing = false
        let next = afterReview
        afterReview = nil
        let ticket = generation
        let result = done.result
        applyingReview = true
        work = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result { try result.applying(choices) }
            await MainActor.run {
                guard let self, self.generation == ticket, case .finished(var current) = self.state else { return }
                self.applyingReview = false
                switch outcome {
                case .success(let revised):
                    current.result = revised
                    current.choices = choices
                    current.reviewed = true
                    current.copied = false
                    self.state = .finished(current)
                    switch next {
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
            await MainActor.run {
                guard let self, self.generation == ticket else { return }
                switch outcome {
                case .success(let result): self.state = .finished(Finished(name: name, source: source, result: result, choices: result.choices))
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
