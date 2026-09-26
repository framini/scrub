import AppKit
import Observation
import ScrubCore
import UniformTypeIdentifiers

enum Source { case file, paste }

struct Finished {
    let name: String
    let source: Source
    let result: ScrubResult
    var savedAs: String?
    var copied = false
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
    var failedSave = false

    // Clear, and any newer input, bumps the generation; work finishing after
    // that is dropped, so cleared content never comes back.
    private var generation = 0
    private var work: Task<Void, Never>?
    private var copiedChangeCount: Int?

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
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let holdsSomething = !(board.types ?? []).isEmpty
            return fail(Self.pastedName, .paste, holdsSomething ? "clipboard_not_text" : "empty_clipboard")
        }
        start(Self.pastedName, .paste, Data(text.utf8))
    }

    func copy() {
        guard case .finished(var done) = state, let text = String(data: done.result.output, encoding: .utf8) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copiedChangeCount = board.changeCount
        done.copied = true
        state = .finished(done)
    }

    func save() {
        guard case .finished(var done) = state else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "scrubbed.\(Self.fileExtension(done.result.format))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.writePrivately(done.result.output, to: url)
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
        let board = NSPasteboard.general
        if board.changeCount == ours { board.clearContents() }
    }

    private func stop() {
        generation += 1
        work?.cancel()
        work = nil
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
        work = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result {
                try Scrubber.scrub(data, name: name) { stage, done, total in
                    Task { @MainActor in
                        guard let self, self.generation == ticket, case .processing = self.state else { return }
                        self.state = .processing(name: name, source: source, stage: stage, done: done, total: total)
                    }
                }
            }
            await MainActor.run {
                guard let self, self.generation == ticket else { return }
                switch outcome {
                case .success(let result): self.state = .finished(Finished(name: name, source: source, result: result))
                case .failure(let error): self.state = .failed(name: name, source: source, code: Self.code(for: error))
                }
            }
        }
    }

    private static func code(for error: Error) -> String {
        switch error as? ScrubError {
        case .notUTF8: "not_utf8"
        case .tooLarge: "too_large"
        case .empty: "empty_file"
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

    /// Owner-only, written in one step: Foundation stages the bytes beside the
    /// target in a location the sandbox allows and renames them over it.
    static func writePrivately(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
