import AppKit
import ScrubCore
import SwiftUI

struct ResultView: View {
    let finished: Finished
    let model: AppModel

    private var total: Int { finished.result.counts.values.reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.line)
            if finished.result.coverage.isReduced {
                coverageNote
                Divider().overlay(Color.line)
            }
            if finished.needsReview {
                reviewBanner
                Divider().overlay(Color.line)
            }
            preview
            if model.draft != nil || !model.pick.isEmpty || model.notice != nil {
                Divider().overlay(Color.line)
                selectionBar
            }
            if model.showingValues {
                Divider().overlay(Color.line)
                ValuesPanel(model: model)
            }
            Divider().overlay(Color.line)
            footer
        }
        .background(Color.snow, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.rule))
        .sheet(isPresented: Binding(get: { model.reviewing }, set: { if !$0 { model.cancelReview() } })) {
            ReviewView(findings: finished.result.uncertain.map(finished.result.revised), choices: finished.choices, onDone: { model.finishReview($0) }, onCancel: { model.cancelReview() },
                       onKind: { finding, kind in model.changeKind(of: [finding.id], to: kind) })
                .preferredColorScheme(.light)
        }
        .sheet(item: Binding(get: { model.placing }, set: { model.placing = $0 })) { finding in
            ReviewView(findings: [finding], title: Copy.placesTitle(finding.original), body: Copy.placesBody, choices: finished.choices, onDone: { model.finishPlaces($0) }, onCancel: { model.placing = nil })
                .preferredColorScheme(.light)
        }
    }

    /// What the stand-ins a selection is on replaced, once each.
    static func originals(of pick: Pick) -> [String] {
        var seen: Set<String> = []
        return (pick.replaced.map(\.original) + pick.marked.map(\.text)).filter { seen.insert($0).inserted }
    }

    /// What the preview's selection stands on, and the one action for it (⌘E):
    /// replace what Scrub missed, as the kind it guessed or one chosen, or keep
    /// the original of what it replaced. One value's stand-in, clicked in the
    /// preview or selected in the Values panel, opens its editor here.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            let pick = model.pick
            if let draft = model.draft {
                ValueEditor(draft: draft, model: model)
            } else if pick.isEmpty, let notice = model.notice {
                if notice.refused {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.ember)
                } else {
                    Image(systemName: notice.undone ? "arrow.uturn.backward" : "checkmark").foregroundStyle(Color.evergreen)
                }
                Text(notice.text).lineLimit(1).truncationMode(.middle).help(notice.text)
                Spacer()
                // A change refused made nothing to undo.
                if notice.refused {
                } else if notice.undone {
                    Button { model.redo() } label: { HStack(spacing: 6) { Text("Redo"); KeyHint(key: "⇧⌘Z") } }
                        .buttonStyle(SecondaryButton())
                        .disabled(!model.canRedo)
                } else {
                    Button { model.undo() } label: { HStack(spacing: 6) { Text("Undo"); KeyHint(key: "⌘Z") } }
                        .buttonStyle(SecondaryButton())
                        .disabled(!model.canUndo)
                }
            } else if !pick.missed.isEmpty {
                Text(Copy.quoted(pick.missed)).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text("isn’t replaced").foregroundStyle(Color.slate)
                Spacer()
                Menu {
                    ForEach(Marks.kinds, id: \.self) { kind in
                        Button(Copy.kind(kind)) { model.markKind = kind }
                    }
                } label: {
                    Text(Copy.kind(model.markKind))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("What to replace it as")
                Button { model.applySelection() } label: {
                    HStack(spacing: 6) { Text("Replace"); KeyHint(key: "⌘E") }
                }
                .buttonStyle(SecondaryButton())
                .help(Copy.replaceSelectionHelp)
            } else {
                // A stand-in the person marked is theirs to take off; one Scrub made, to keep the original of.
                let byHand = pick.replaced.isEmpty
                Text(byHand ? "Marked by you, for" : "Stand-in for").foregroundStyle(Color.slate)
                Text(Copy.quoted(Self.originals(of: pick))).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { model.keepOriginal() } label: {
                    HStack(spacing: 6) { Text(byHand ? Copy.removeMark : "Keep original"); KeyHint(key: "⌘E") }
                }
                .buttonStyle(SecondaryButton())
                .help(byHand ? Copy.removeMarkHelp : Copy.keepOriginalHelp)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.mist, in: .rect)
        .disabled(model.applyingReview)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(finished.result.format.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.evergreen)
                .frame(width: 40, height: 40)
                .background(Color.lichen, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(total == 1 ? "1 value replaced" : "\(total) values replaced").font(.system(size: 17, weight: .semibold))
                Text("\(finished.name) · Review before sharing").font(.system(size: 13)).foregroundStyle(Color.slate)
            }
            Spacer()
            status
            Button { model.clear() } label: {
                HStack(spacing: 6) { Text("Start over"); KeyHint(key: "esc") }
            }
            .buttonStyle(SecondaryButton())
            // While a value's editor is open, esc closes it instead.
            .keyboardShortcut(model.draft == nil ? .cancelAction : nil)
            Button { model.copy() } label: {
                HStack(spacing: 6) { Text(finished.copied ? "Copied" : "Copy"); KeyHint(key: "⌘C") }
            }
            .buttonStyle(SecondaryButton())
            .modifier(ShortcutPress(shortcut: .copy, pulse: model.pulse, tint: Color.evergreen.opacity(0.14)))
            Button { model.save() } label: {
                HStack(spacing: 6) { Text(finished.savedAs == nil ? "Save…" : "Save again…"); KeyHint(key: "⌘S", onDark: true) }
            }
            .buttonStyle(PrimaryButton())
            .modifier(ShortcutPress(shortcut: .save, pulse: model.pulse, tint: Color.snow.opacity(0.22)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var status: some View {
        if model.applyingReview {
            ProgressView().controlSize(.small)
        } else if model.failedSave {
            Text("Not saved").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ember)
        } else if let saved = finished.savedAs {
            Text("Saved as \(saved)").font(.system(size: 12)).foregroundStyle(Color.slate)
        }
    }

    /// While findings wait to be checked: what Copy and Save will ask first, and the way to it now.
    private var reviewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.ember)
            Text(Copy.reviewBanner(finished.result.uncertain.count)).fontWeight(.semibold)
            Text(Copy.reviewBannerBody).foregroundStyle(Color.slate).lineLimit(1)
            Spacer(minLength: 8)
            Button { model.review() } label: { Text("Check now") }
                .buttonStyle(SecondaryButton())
                .help("See the replacements Scrub is least sure of, and leave any that aren’t personal")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.emberWash, in: .rect)
    }

    /// Some of Scrub's own detectors didn't load, so this scrub found less than it could.
    private var coverageNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.ember)
            VStack(alignment: .leading, spacing: 2) {
                Text(Copy.reducedCoverageTitle).fontWeight(.semibold)
                Text(Copy.reducedCoverage(finished.result.coverage.missing)).foregroundStyle(Color.slate).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.emberWash, in: .rect)
    }

    @ViewBuilder private var preview: some View {
        switch finished.result.preview {
        case .text(let text, let marks, let truncated):
            VStack(spacing: 0) {
                // Selectable always, so a value can be marked; it leaves the app only as `AppModel.selectionMayLeave` allows.
                PreviewText(text: text, marks: marks, reveal: model.reveal, model: model)
                if truncated {
                    Text("Showing the start of the file. The saved or copied file has everything.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { Divider().overlay(Color.line) }
                }
            }
        case .table(let columns, let rows, let rowCount, let marks):
            TablePreview(columns: columns, rows: rows, rowCount: rowCount, marks: marks, reveal: model.reveal, model: model)
        }
    }

    /// What was replaced, as many kinds as fit; and on the right, how the
    /// review went, the person's own changes, and the way back through them.
    private var footer: some View {
        HStack(spacing: 14) {
            CountsRow(groups: Copy.grouped(finished.result.counts), neutralized: finished.result.neutralized)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            let uncertain = finished.result.uncertain
            if finished.reviewed, !uncertain.isEmpty {
                Button { model.review() } label: {
                    Text(Copy.checked(leaving: finished.choices.leftCount(of: uncertain))).foregroundStyle(Color.slate)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("See the replacements Scrub was least sure of again")
            }
            let values = model.values
            let marked = values.filter { $0.id < 0 }.count, keptCount = values.filter(\.kept).count, edited = values.filter { $0.id >= 0 && $0.edited }.count
            if marked + keptCount + edited > 0 {
                Button { model.showValues(.yours) } label: {
                    Text(Copy.changes(marked: marked, kept: keptCount, edited: edited)).fontWeight(.semibold).foregroundStyle(Color.slate)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(Copy.changesHelp)
            }
            Button { model.toggleValues() } label: {
                Label(Copy.values, systemImage: "list.bullet").foregroundStyle(model.showingValues ? Color.evergreen : Color.slate)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(Copy.valuesHelp)
            if model.canUndo || model.canRedo {
                HStack(spacing: 2) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 22) }
                        .disabled(!model.canUndo)
                        .help("\(model.undoTitle) (⌘Z)")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 24, height: 22) }
                        .disabled(!model.canRedo)
                        .help("\(model.redoTitle) (⇧⌘Z)")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.slate)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.mist, in: .rect(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
    }

    /// Marks are UTF-16 offsets, the same units NSString ranges use.
    static func highlighted(_ text: String, _ marks: [Mark]) -> AttributedString {
        (try? AttributedString(styled(text, marks), including: \.appKit)) ?? AttributedString(text)
    }

    /// The text with each stand-in marked, in `font` when given, for the AppKit previews.
    static func styled(_ text: String, _ marks: [Mark], font: NSFont? = nil, lineSpacing: CGFloat = 0) -> NSMutableAttributedString {
        var base: [NSAttributedString.Key: Any] = [:]
        if let font {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            base = [.font: font, .foregroundColor: NSColor(Color.ink), .paragraphStyle: paragraph]
        }
        let styled = NSMutableAttributedString(string: text, attributes: base)
        let length = (text as NSString).length
        for mark in marks where mark.range.lowerBound >= 0 && mark.range.upperBound <= length {
            let range = NSRange(location: mark.range.lowerBound, length: mark.range.count)
            styled.addAttributes([.backgroundColor: NSColor(Color.lichen), .foregroundColor: NSColor(Color.evergreen)], range: range)
            // The person's own marks are underlined, so they can be found and taken off.
            if mark.byHand { styled.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue, .underlineColor: NSColor(Color.evergreen)], range: range) }
        }
        return styled
    }
}

private struct TablePreview: View {
    let columns: [String]
    let rows: [[String]]
    let rowCount: Int
    let reveal: Reveal?
    let model: AppModel
    private let widths: [CGFloat]
    private let cellMarks: [Int: [Int: [Mark]]]
    /// The row a value was last shown in, lit for a moment.
    @State private var lit: Int?

    init(columns: [String], rows: [[String]], rowCount: Int, marks: [TableMark], reveal: Reveal? = nil, model: AppModel) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        self.reveal = reveal
        self.model = model
        widths = columns.indices.map { column in
            let longest = max(columns[column].count, rows.prefix(100).compactMap { column < $0.count ? $0[column].count : nil }.max() ?? 0)
            return min(240, max(100, CGFloat(longest * 8 + 12)))
        }
        var grouped: [Int: [Int: [Mark]]] = [:]
        for mark in marks { grouped[mark.row, default: [:]][mark.column, default: []].append(Mark(range: mark.range, entity: mark.entity, byHand: mark.byHand)) }
        cellMarks = grouped
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns.indices, id: \.self) { column in
                            Text(ResultView.highlighted(columns[column], cellMarks[TableMark.header]?[column] ?? []))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.slate)
                                .frame(width: widths[column], alignment: .leading)
                                .padding(.trailing, 24)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                    .background(Color.snow, in: .rect)
                    .overlay(alignment: .bottom) { Divider().overlay(Color.line) }
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(rows.indices, id: \.self) { row in
                                    HStack(spacing: 0) {
                                        ForEach(columns.indices, id: \.self) { column in
                                            cell(row: row, column: column)
                                                .font(.system(size: 13))
                                                .lineLimit(1)
                                                .frame(width: widths[column], alignment: .leading)
                                                .padding(.trailing, 24)
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .frame(height: 44)
                                    .background(lit == row ? Color.lichen : Color.clear)
                                    .overlay(alignment: .bottom) { Divider().overlay(Color.fog) }
                                    .id(row)
                                }
                            }
                        }
                        .onChange(of: reveal) { _, reveal in
                            guard let reveal, let row = Self.row(of: reveal, rows: rows, marks: cellMarks) else { return }
                            reader.scrollTo(row, anchor: .center)
                            lit = row
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                if lit == row { withAnimation(.easeOut(duration: 0.3)) { lit = nil } }
                            }
                        }
                    }
                }
            }
            if rowCount > rows.count {
                Text("Showing \(rows.count) of \(rowCount) rows. The saved or copied file has all of them.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.slate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { Divider().overlay(Color.line) }
            }
        }
    }
    /// The first row shown that holds the value: its stand-in where one is
    /// marked, or else its original, where it was left as written.
    static func row(of reveal: Reveal, rows: [[String]], marks: [Int: [Int: [Mark]]]) -> Int? {
        let standIn = reveal.standIn.lowercased()
        for (row, cells) in rows.enumerated() {
            for (column, cell) in cells.enumerated() where (marks[row]?[column] ?? []).contains(where: { PreviewText.substring(cell, $0.range).lowercased() == standIn }) { return row }
        }
        return rows.firstIndex { $0.contains { $0.range(of: reveal.original, options: .caseInsensitive) != nil } }
    }

    @ViewBuilder private func cell(row: Int, column: Int) -> some View {
        let value = column < rows[row].count ? rows[row][column] : ""
        let marks = cellMarks[row]?[column] ?? []
        let firstLine = (value as NSString).rangeOfCharacter(from: .newlines).location
        if firstLine != NSNotFound {
            // Only the first line fits the row; the ellipsis is marked when a
            // replacement sits in the lines it hides.
            let shown = marks.compactMap { mark in mark.range.lowerBound < firstLine ? Mark(range: mark.range.lowerBound..<min(mark.range.upperBound, firstLine), entity: mark.entity, byHand: mark.byHand) : nil }
            let hidden = marks.contains { $0.range.upperBound > firstLine }
            let line = (value as NSString).substring(to: firstLine)
            let length = (line as NSString).length
            PreviewCell(text: line + " …", marks: shown + (hidden ? [Mark(range: (length + 1)..<(length + 2), entity: "")] : []), column: columns[column], model: model).help(value)
        } else {
            PreviewCell(text: value, marks: marks, column: columns[column], model: model).help(value)
        }
    }

}

/// The counts of what was replaced, by kind, largest first: as many as fit
/// the footer, and the rest behind "+N more".
private struct CountsRow: View {
    let groups: [(label: String, count: Int)]
    let neutralized: Int
    @State private var showingAll = false

    private var items: [(label: String, count: String)] {
        groups.map { ($0.label, "\($0.count)") } + (neutralized > 0 ? [(neutralized == 1 ? "Formula made inert" : "Formulas made inert", "\(neutralized)")] : [])
    }

    var body: some View {
        let items = items
        ViewThatFits(in: .horizontal) {
            ForEach((0...items.count).reversed(), id: \.self) { shown in
                HStack(spacing: 14) {
                    ForEach(items.prefix(shown), id: \.label) { item($0) }
                    if shown < items.count { more(items.count - shown) }
                }
                .fixedSize()
            }
        }
    }

    private func item(_ item: (label: String, count: String)) -> some View {
        HStack(spacing: 4) {
            Text(item.label).foregroundStyle(Color.slate)
            Text(item.count).fontWeight(.semibold)
        }
    }

    private func more(_ hidden: Int) -> some View {
        Button { showingAll = true } label: {
            Text(Copy.moreCounts(hidden)).fontWeight(.semibold).foregroundStyle(Color.slate).underline()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAll, arrowEdge: .top) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(items, id: \.label) { item in
                    GridRow {
                        Text(item.label).foregroundStyle(Color.slate)
                        Text(item.count).fontWeight(.semibold).gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.system(size: 12))
            .padding(14)
        }
    }
}
