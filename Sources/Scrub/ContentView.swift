import ScrubCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let model: AppModel
    @State private var dragging = false

    var body: some View {
        // The title bar is hidden; its height is the top safe area, and the
        // header fills exactly that row so it centres on the traffic lights.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.frame(height: max(geometry.safeAreaInsets.top, 28))
                screen
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color.fog)
        .foregroundStyle(Color.ink)
        .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
            guard let provider = providers.first else { return false }
            let ticket = model.beginDrop()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.open(url, ticket: ticket) }
            }
            return true
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Label("On-device only", systemImage: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.evergreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.lichen, in: .capsule)
        }
    }

    @ViewBuilder private var screen: some View {
        if dragging {
            DropView(dragging: true, model: model)
        } else {
            switch model.state {
            case .idle: DropView(dragging: false, model: model)
            case .processing(let name, let source, let stage, let done, let total):
                ProcessingView(name: name, source: source, stage: stage, done: done, total: total, model: model)
            case .finished(let finished): ResultView(finished: finished, model: model)
            case .failed(let name, let source, let code): FailedView(name: name, source: source, code: code, model: model)
            }
        }
    }
}

struct DropView: View {
    let dragging: Bool
    let model: AppModel

    var body: some View {
        Card(dashed: true) {
            VStack(spacing: 28) {
                Image(systemName: dragging ? "arrow.down.to.line" : "doc.text")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.evergreen)
                VStack(spacing: 10) {
                    Text(dragging ? "Drop to clean it" : "Drop a file or paste text")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.6)
                    (Text("Replaces personal details with realistic stand-ins. Runs offline; nothing you drop here leaves your Mac. ")
                        + Text(Image(systemName: "info.circle")).foregroundStyle(Color.evergreen))
                        .font(.system(size: 15))
                        .foregroundStyle(Color.slate)
                        .multilineTextAlignment(.center)
                        .frame(width: 440)
                        .help(Copy.howItWorks)
                }
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Button("Choose file…") { model.choose() }.buttonStyle(PrimaryButton())
                        Button { model.paste() } label: {
                            HStack(spacing: 6) {
                                Text("Paste")
                                KeyHint(key: "⌘V")
                            }
                        }
                        .buttonStyle(SecondaryButton())
                    }
                    Text(Copy.formats).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.slate)
                }
                .opacity(dragging ? 0 : 1)
            }
        }
        .background(dragging ? Color.lichen.opacity(0.4) : .clear, in: .rect(cornerRadius: 10))
    }
}

struct ProcessingView: View {
    let name: String
    let source: Source
    let stage: Stage
    let done: Int
    let total: Int
    let model: AppModel

    private var percent: Int {
        switch stage {
        case .starting: 4
        case .finding: total > 0 ? 10 + 80 * done / total : 10
        case .checking: 95
        }
    }

    var body: some View {
        Card {
            VStack(spacing: 28) {
                ZStack {
                    Circle().stroke(Color.line, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: Double(percent) / 100)
                        .stroke(Color.evergreen, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: percent)
                    Text("\(percent)%").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 120, height: 120)
                VStack(spacing: 6) {
                    Text(source == .paste ? "Cleaning pasted text" : "Cleaning \(name)").font(.system(size: 20, weight: .semibold))
                    Text("Everything stays on this Mac").font(.system(size: 14)).foregroundStyle(Color.slate)
                }
                Button { model.clear() } label: {
                    HStack(spacing: 6) { Text("Cancel"); KeyHint(key: "esc") }
                }
                .buttonStyle(SecondaryButton())
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct FailedView: View {
    let name: String
    let source: Source
    let code: String
    let model: AppModel

    var body: some View {
        let failure = Copy.failure(code)
        Card {
            VStack(spacing: 22) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.ember)
                    .frame(width: 56, height: 56)
                    .background(Color.emberWash, in: .circle)
                VStack(spacing: 8) {
                    if source == .file { Text(name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.slate) }
                    Text(failure.title).font(.system(size: 22, weight: .semibold))
                    Text(failure.body).font(.system(size: 15)).foregroundStyle(Color.slate).multilineTextAlignment(.center).frame(width: 440)
                }
                if source == .paste {
                    HStack(spacing: 8) {
                        Button("Paste again") { model.paste() }.buttonStyle(PrimaryButton())
                        Button("Choose file…") { model.choose() }.buttonStyle(SecondaryButton())
                    }
                } else {
                    Button("Choose another file…") { model.choose() }.buttonStyle(PrimaryButton())
                }
                Button("Start over") { model.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.slate)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
