import ScrubCore
import SwiftUI

/// The findings Scrub is least sure of, each with where it stands, to keep
/// replaced or leave as written before the file goes anywhere. A choice
/// covers every place the value appears, or one place at a time. The same
/// sheet chooses one value's places from the Values panel, under its own title.
struct ReviewView: View {
    let findings: [Finding]
    let title: String?
    let message: String?
    let onDone: (Choices) -> Void
    let onCancel: () -> Void
    /// Reads a finding as another kind ("VIA GARIBALDI" as a street, not a name); nil where the sheet can't.
    let onKind: ((Finding, String) -> Void)?
    @State private var choices: Choices

    init(findings: [Finding], title: String? = nil, body: String? = nil, choices: Choices, onDone: @escaping (Choices) -> Void, onCancel: @escaping () -> Void, onKind: ((Finding, String) -> Void)? = nil) {
        self.findings = findings
        self.title = title
        self.message = body
        self.onDone = onDone
        self.onCancel = onCancel
        self.onKind = onKind
        _choices = State(initialValue: choices)
    }

    private var leaving: Int { findings.filter { finding in finding.places.contains { choices.leaves($0, of: finding) } }.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title ?? Copy.reviewTitle(findings.count)).font(.system(size: 17, weight: .semibold))
                Text(message ?? Copy.reviewBody).font(.system(size: 13)).foregroundStyle(Color.slate).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider().overlay(Color.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(findings) { finding in
                        ReviewRow(finding: finding, choices: $choices, placeByPlace: title != nil, onKind: onKind)
                        Divider().overlay(Color.fog)
                    }
                }
            }
            Divider().overlay(Color.line)
            HStack(spacing: 14) {
                if !findings.isEmpty {
                    Button("Replace all") { for finding in findings { choices.set(finding, leave: false) } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.slate)
                    Button("Leave all") { for finding in findings { choices.set(finding, leave: true) } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.slate)
                }
                Spacer()
                if !findings.isEmpty {
                    Text(Copy.reviewTally(leaving: leaving, of: findings.count)).font(.system(size: 12)).foregroundStyle(Color.slate)
                }
                Button { onCancel() } label: {
                    HStack(spacing: 6) { Text("Cancel"); KeyHint(key: "esc") }
                }
                .buttonStyle(SecondaryButton())
                .keyboardShortcut(.cancelAction)
                Button { onDone(choices) } label: {
                    HStack(spacing: 6) { Text("Done"); KeyHint(key: "↩", onDark: true) }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.mist, in: .rect)
        }
        .frame(width: 680, height: 540)
        .background(Color.snow, in: .rect)
        .foregroundStyle(Color.ink)
    }

}

private struct ReviewRow: View {
    let finding: Finding
    @Binding var choices: Choices
    @State private var placeByPlace: Bool
    let onKind: ((Finding, String) -> Void)?

    init(finding: Finding, choices: Binding<Choices>, placeByPlace: Bool = false, onKind: ((Finding, String) -> Void)? = nil) {
        self.finding = finding
        _choices = choices
        _placeByPlace = State(initialValue: placeByPlace)
        self.onKind = onKind
    }

    /// Replace or leave everywhere; neither while places differ.
    private enum Everywhere: Hashable { case replace, leave, mixed }
    private var everywhere: Binding<Everywhere> {
        Binding(
            get: {
                let left = finding.places.filter { choices.leaves($0, of: finding) }.count
                return left == 0 ? .replace : left == finding.places.count ? .leave : .mixed
            },
            set: { if $0 != .mixed { choices.set(finding, leave: $0 == .leave) } }
        )
    }
    private var replaced: Bool { everywhere.wrappedValue != .leave }

    /// The kind, as a menu of the others where the sheet can change it: picking
    /// one replaces the value as that kind everywhere it appears.
    @ViewBuilder private var kindBadge: some View {
        let label = HStack(spacing: 3) {
            Text(Copy.kind(finding.entity))
            if onKind != nil { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.evergreen)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Color.lichen, in: .rect(cornerRadius: 4))
        if let onKind {
            Menu {
                ForEach(ValueEditor.kinds(including: finding.entity), id: \.self) { kind in
                    Button(Copy.kind(kind)) {
                        choices.set(finding, leave: false)
                        onKind(finding, kind)
                    }
                    .disabled(Copy.kind(kind) == Copy.kind(finding.entity))
                }
            } label: { label }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Copy.kindHelp)
        } else {
            label
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        kindBadge
                        Text(finding.original).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.slate)
                        Text(finding.standIn).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.slate).lineLimit(1).truncationMode(.middle)
                        if finding.occurrences > 1 {
                            Text("\(finding.occurrences) places").font(.system(size: 12)).foregroundStyle(Color.slate)
                        }
                    }
                    if let reason = Copy.reason(finding) {
                        Text(reason).font(.system(size: 12)).foregroundStyle(Color.ember)
                    }
                    ForEach(Array(finding.excerpts.prefix(2).enumerated()), id: \.offset) { _, excerpt in
                        Text(excerptText(excerpt, replaced: replaced))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.slate)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: everywhere) {
                    Text("Replace").tag(Everywhere.replace)
                    Text("Leave").tag(Everywhere.leave)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Color.evergreen)
                .frame(width: 150)
                .help(replaced ? Copy.replaceHelp : Copy.leaveHelp(finding.original))
            }
            if finding.occurrences > 1 {
                DisclosureGroup(Copy.places(finding.occurrences), isExpanded: $placeByPlace) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(finding.places) { place in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Toggle(Copy.leaveHere, isOn: Binding(get: { choices.leaves(place, of: finding) }, set: { choices.set(place, leave: $0) }))
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 12))
                                if let excerpt = place.excerpt {
                                    Text(excerptText(excerpt, replaced: !choices.leaves(place, of: finding)))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.slate)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.slate)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .opacity(replaced ? 1 : 0.75)
    }

    /// The line as the cleaned file reads, with the stand-in marked, or the original where it will be left.
    private func excerptText(_ excerpt: Excerpt, replaced: Bool) -> AttributedString {
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
