import AppKit
import ScrubCore
import SwiftUI

/// Where a value stands: replaced, left as written, still to check, or
/// marked by the person.
enum ValueStatus: Hashable, Sendable, CaseIterable { case replaced, left, toCheck, marked }

/// Which rows the Values panel shows: all, one status, or what the person changed.
enum ValueFilter: Hashable, Sendable {
    case all
    case status(ValueStatus)
    /// Values the person marked, kept or edited: what the footer counts as theirs.
    case yours

    static let menu: [ValueFilter] = [.all] + ValueStatus.allCases.map { .status($0) } + [.yours]

    func admits(_ row: ValueRow) -> Bool {
        switch self {
        case .all: true
        case .status(let status): row.status == status
        case .yours: row.yours
        }
    }
}

/// One value in the Values panel, as the result writes it now.
struct ValueRow: Identifiable, Equatable, Sendable {
    let id: Finding.ID
    let finding: Finding
    let status: ValueStatus
    /// Scrub was sure of it, and the person left it as written somewhere.
    let kept: Bool
    /// Its kind or stand-in differs from the scrub as made.
    let edited: Bool
    /// Its original and stand-in, folded, for the search.
    let search: String

    var yours: Bool { id < 0 || kept || edited }

    private static let locale = Locale(identifier: "en_US_POSIX")
    static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale) }

    /// A row for every value `result` writes, in the order Scrub met them, then the marks.
    static func rows(of result: ScrubResult, choices: Choices, edits: Edits, reviewed: Bool) -> [ValueRow] {
        let made = result.findings
        return result.current.map { finding in
            let leaving = finding.places.filter { choices.leaves($0, of: finding) }.count
            let status: ValueStatus = finding.id < 0 ? .marked
                : finding.needsReview && !reviewed ? .toCheck
                : leaving == finding.places.count && leaving > 0 ? .left : .replaced
            let asMade = finding.id >= 0 && made.indices.contains(finding.id) ? made[finding.id] : nil
            let edited = asMade.map { $0.standIn != finding.standIn || $0.entity != finding.entity } ?? false
            return ValueRow(id: finding.id, finding: finding, status: status, kept: finding.id >= 0 && !finding.needsReview && leaving > 0,
                            edited: edited || finding.id >= 0 && edits.touches(finding.id), search: fold(finding.original + "\n" + finding.standIn))
        }
    }
}

/// Every value Scrub found or the person marked, under the preview: to
/// search, filter by kind and status, and change one at a time or many at
/// once. Selecting one row shows it in the preview and opens its editor.
struct ValuesPanel: View {
    let model: AppModel

    var body: some View {
        let rows = model.visibleValues
        VStack(spacing: 0) {
            toolbar(shown: rows.count)
            Divider().overlay(Color.line)
            columns
            Divider().overlay(Color.fog)
            if rows.isEmpty {
                Text(model.values.isEmpty ? Copy.noValues : Copy.noMatches)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.slate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            ValueRowView(row: row, selected: model.selectedValues.contains(row.id))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let flags = NSEvent.modifierFlags
                                    model.selectValue(row.id, toggling: flags.contains(.command), extending: flags.contains(.shift))
                                }
                        }
                    }
                }
            }
            if !model.selectedValues.isEmpty {
                Divider().overlay(Color.line)
                actions
            }
        }
        .frame(height: 260)
        .background(Color.snow)
        .font(.system(size: 12))
    }

    private func toolbar(shown: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.slate)
                TextField(Copy.searchValues, text: Binding(get: { model.valueSearch }, set: { model.valueSearch = $0 }))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .frame(minWidth: 140, maxWidth: 260)
            .background(Color.mist, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.rule))
            Menu {
                Button(Copy.allKinds) { model.valueKind = nil }
                Divider()
                ForEach(model.valueKinds, id: \.self) { kind in Button(kind) { model.valueKind = kind } }
            } label: {
                Text(model.valueKind ?? Copy.allKinds)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Menu {
                ForEach(ValueFilter.menu, id: \.self) { filter in Button(Copy.filter(filter)) { model.valueFilter = filter } }
            } label: {
                Text(Copy.filter(model.valueFilter))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 8)
            Text(Copy.valueCount(shown: shown, of: model.values.count)).foregroundStyle(Color.slate).fixedSize()
            Button { model.toggleValues() } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.slate)
                .help("\(Copy.hideValues) (⇧⌘L)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.mist)
    }

    private var columns: some View {
        HStack(spacing: 12) {
            Text(Copy.original).frame(maxWidth: .infinity, alignment: .leading)
            Text(Copy.kindColumn).frame(width: ValueRowView.kindWidth, alignment: .leading)
            Text(Copy.standIn).frame(maxWidth: .infinity, alignment: .leading)
            Text(Copy.placesColumn).frame(width: ValueRowView.placesWidth, alignment: .trailing)
            Text(Copy.statusColumn).frame(width: ValueRowView.statusWidth, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.slate)
        .padding(.horizontal, 20)
        .frame(height: 24)
    }

    /// What can be done to the selected rows at once.
    private var actions: some View {
        let selected = model.selectedValues
        let one = selected.count == 1 ? model.values.first { selected.contains($0.id) } : nil
        return HStack(spacing: 10) {
            Text(Copy.selected(selected.count)).foregroundStyle(Color.slate).fixedSize()
            Spacer(minLength: 8)
            if let one, one.finding.places.count > 1 {
                Button(Copy.placeByPlace) { model.choosePlaces(one.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.slate)
                    .fixedSize()
                    .help(Copy.placeByPlaceHelp)
            }
            Menu {
                ForEach(Marks.kinds, id: \.self) { kind in Button(Copy.kind(kind)) { model.changeKind(of: selected, to: kind) } }
            } label: {
                Text(Copy.changeKind)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(Copy.kindHelp)
            Button { model.keepValues(selected) } label: {
                HStack(spacing: 6) { Text(Copy.keepOriginalAction); KeyHint(key: "⌘E") }
            }
            .buttonStyle(SecondaryButton())
            .fixedSize()
            .help(Copy.keepOriginalHelp)
            Button(Copy.replaceAgain) { model.replaceValuesAgain(selected) }
                .buttonStyle(SecondaryButton())
                .fixedSize()
                .help(Copy.replaceAgainHelp)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.mist)
        .disabled(model.applyingReview)
    }
}

private struct ValueRowView: View {
    static let kindWidth: CGFloat = 84
    static let placesWidth: CGFloat = 44
    static let statusWidth: CGFloat = 112
    let row: ValueRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(row.finding.original)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Copy.kind(row.finding.entity))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.evergreen)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(selected ? Color.snow : Color.lichen, in: .rect(cornerRadius: 4))
                .frame(width: Self.kindWidth, alignment: .leading)
            Text(row.status == .left ? row.finding.original : row.finding.standIn)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(row.status == .left ? Color.slate.opacity(0.7) : Color.slate)
                .strikethrough(row.status == .left, color: Color.slate.opacity(0.5))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.finding.places.count)")
                .monospacedDigit()
                .foregroundStyle(Color.slate)
                .frame(width: Self.placesWidth, alignment: .trailing)
            HStack(spacing: 6) {
                Circle().fill(Self.tint(row.status)).frame(width: 6, height: 6)
                Text(Copy.status(row.status)).foregroundStyle(row.status == .toCheck ? Color.ember : Color.ink).lineLimit(1)
            }
            .frame(width: Self.statusWidth, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 28)
        .background(selected ? Color.lichen : Color.clear)
        .overlay(alignment: .bottom) { Divider().overlay(Color.fog) }
    }

    static func tint(_ status: ValueStatus) -> Color {
        switch status {
        case .replaced, .marked: Color.evergreen
        case .left: Color.dash
        case .toCheck: Color.ember
        }
    }
}

/// The editor for one value, in the bar under the preview: what it
/// replaced and in how many places, the kind it is read as, the text that
/// replaces it, and the way to keep its original instead.
struct ValueEditor: View {
    let draft: Draft
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(Copy.editorFor).foregroundStyle(Color.slate)
                Text(Copy.quoted([draft.original])).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text("· " + Copy.placesCount(draft.places)).foregroundStyle(Color.slate).fixedSize()
                Spacer(minLength: 8)
                Menu {
                    ForEach(Self.kinds(including: draft.initialKind), id: \.self) { kind in
                        Button(Copy.kind(kind)) { model.draft?.kind = kind }
                    }
                } label: {
                    Text(Copy.kind(draft.kind))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(Copy.kindHelp)
                Button { model.keepDraft() } label: {
                    HStack(spacing: 6) { Text(draft.byHand ? Copy.removeMark : Copy.keepOriginalAction); KeyHint(key: "⌘E") }
                }
                .buttonStyle(SecondaryButton())
                .fixedSize()
                .help(draft.byHand ? Copy.removeMarkHelp : Copy.keepOriginalHelp)
            }
            HStack(spacing: 8) {
                Text(Copy.replaceWith).foregroundStyle(Color.slate).fixedSize()
                TextField("", text: Binding(get: { model.draft?.text ?? "" }, set: { text in
                    model.draft?.text = text
                    model.draft?.refusal = nil
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.snow, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(draft.refusal == nil ? Color.rule : Color.ember))
                .onSubmit { model.applyDraft() }
                .help(Copy.replaceWithHelp)
                Button { model.cancelDraft() } label: {
                    HStack(spacing: 6) { Text(Copy.cancel); KeyHint(key: "esc") }
                }
                .buttonStyle(SecondaryButton())
                .fixedSize()
                .keyboardShortcut(.cancelAction)
                Button { model.applyDraft() } label: {
                    HStack(spacing: 6) { Text(Copy.apply); KeyHint(key: "↩", onDark: true) }
                }
                .buttonStyle(PrimaryButton())
                .fixedSize()
                .keyboardShortcut(.defaultAction)
                .opacity(draft.changed ? 1 : 0.5)
                .disabled(!draft.changed)
            }
            if let refusal = draft.refusal {
                Label(Copy.refusal(refusal, original: draft.original), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.ember)
            }
        }
    }

    /// The kinds a person can pick, the value's own among them: in place of
    /// the one named the same ("Name" for a first name), or first.
    static func kinds(including own: String) -> [String] {
        let label = Copy.kind(own)
        guard Marks.kinds.contains(where: { Copy.kind($0) == label }) else { return [own] + Marks.kinds }
        return Marks.kinds.map { Copy.kind($0) == label ? own : $0 }
    }
}
