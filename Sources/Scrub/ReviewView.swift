import ScrubCore
import SwiftUI

/// The findings Scrub is least sure of, each with where it was replaced, to
/// keep replaced or leave as written before the file goes anywhere. A choice
/// covers every place the value appears.
struct ReviewView: View {
    let findings: [Finding]
    let onDone: (Set<Finding.ID>) -> Void
    let onCancel: () -> Void
    @State private var leave: Set<Finding.ID>

    init(findings: [Finding], skipped: Set<Finding.ID>, onDone: @escaping (Set<Finding.ID>) -> Void, onCancel: @escaping () -> Void) {
        self.findings = findings
        self.onDone = onDone
        self.onCancel = onCancel
        _leave = State(initialValue: skipped)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.reviewTitle(findings.count)).font(.system(size: 17, weight: .semibold))
                Text(Copy.reviewBody).font(.system(size: 13)).foregroundStyle(Color.slate).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider().overlay(Color.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(findings) { finding in
                        ReviewRow(finding: finding, replaced: Binding(
                            get: { !leave.contains(finding.id) },
                            set: { if $0 { leave.remove(finding.id) } else { leave.insert(finding.id) } }
                        ))
                        Divider().overlay(Color.fog)
                    }
                }
            }
            Divider().overlay(Color.line)
            HStack(spacing: 14) {
                Button("Replace all") { leave = [] }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.slate)
                Button("Leave all") { leave = Set(findings.map(\.id)) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.slate)
                Spacer()
                Text(Copy.reviewTally(leaving: leave.count, of: findings.count)).font(.system(size: 12)).foregroundStyle(Color.slate)
                Button { onCancel() } label: {
                    HStack(spacing: 6) { Text("Cancel"); KeyHint(key: "esc") }
                }
                .buttonStyle(SecondaryButton())
                .keyboardShortcut(.cancelAction)
                Button { onDone(leave) } label: {
                    HStack(spacing: 6) { Text("Done"); KeyHint(key: "↩", onDark: true) }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.mist)
        }
        .frame(width: 680, height: 540)
        .background(Color.snow)
        .foregroundStyle(Color.ink)
    }
}

private struct ReviewRow: View {
    let finding: Finding
    @Binding var replaced: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(Copy.kind(finding.entity))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.evergreen)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.lichen, in: .rect(cornerRadius: 4))
                    Text(finding.original).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.slate)
                    Text(finding.standIn).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.slate).lineLimit(1).truncationMode(.middle)
                    if finding.occurrences > 1 {
                        Text("\(finding.occurrences) places").font(.system(size: 12)).foregroundStyle(Color.slate)
                    }
                }
                ForEach(Array(finding.excerpts.prefix(2).enumerated()), id: \.offset) { _, excerpt in
                    Text(excerptText(excerpt))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.slate)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: $replaced) {
                Text("Replace").tag(true)
                Text("Leave").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.evergreen)
            .frame(width: 150)
            .help(replaced ? Copy.replaceHelp : Copy.leaveHelp(finding.original))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .opacity(replaced ? 1 : 0.75)
    }

    /// The line as the cleaned file reads, with the stand-in marked, or the original where it will be left.
    private func excerptText(_ excerpt: Excerpt) -> AttributedString {
        var before = AttributedString(excerpt.before)
        var middle = AttributedString(replaced ? excerpt.standIn : finding.original)
        middle.backgroundColor = replaced ? Color.lichen : Color.emberWash
        middle.foregroundColor = replaced ? Color.evergreen : Color.ember
        let after = AttributedString(excerpt.after)
        before.append(middle)
        before.append(after)
        return before
    }
}
