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
            preview
            Divider().overlay(Color.line)
            footer
        }
        .background(Color.snow, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.rule))
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
            .keyboardShortcut(.cancelAction)
            Button { model.copy() } label: {
                HStack(spacing: 6) { Text(finished.copied ? "Copied" : "Copy"); KeyHint(key: "⇧⌘C") }
            }
            .buttonStyle(SecondaryButton())
            .modifier(ShortcutPress(shortcut: .copy, pulse: model.pulse))
            Button { model.save() } label: {
                HStack(spacing: 6) { Text(finished.savedAs == nil ? "Save…" : "Save again…"); KeyHint(key: "⌘S", onDark: true) }
            }
            .buttonStyle(PrimaryButton())
            .modifier(ShortcutPress(shortcut: .save, pulse: model.pulse))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var status: some View {
        if model.failedSave {
            Text("Not saved").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ember)
        } else if let saved = finished.savedAs {
            Text("Saved as \(saved)").font(.system(size: 12)).foregroundStyle(Color.slate)
        }
    }

    @ViewBuilder private var preview: some View {
        switch finished.result.preview {
        case .text(let text, let marks, let truncated):
            VStack(spacing: 0) {
                ScrollView {
                    Text(Self.highlighted(text, marks))
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
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
            TablePreview(columns: columns, rows: rows, rowCount: rowCount, marks: marks)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            ForEach(Copy.grouped(finished.result.counts), id: \.label) { group in
                HStack(spacing: 4) {
                    Text(group.label).foregroundStyle(Color.slate)
                    Text("\(group.count)").fontWeight(.semibold)
                }
            }
            if !finished.result.unresolved.isEmpty {
                Text("\(finished.result.unresolved.count) left to review").fontWeight(.semibold).foregroundStyle(Color.ember)
            }
            if finished.result.neutralized > 0 {
                Text("\(finished.result.neutralized) \(finished.result.neutralized == 1 ? "formula" : "formulas") made inert")
                    .foregroundStyle(Color.slate)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.mist)
    }

    /// Marks are UTF-16 offsets, the same units NSString ranges use.
    static func highlighted(_ text: String, _ marks: [Mark]) -> AttributedString {
        let styled = NSMutableAttributedString(string: text)
        let length = (text as NSString).length
        for mark in marks where mark.range.lowerBound >= 0 && mark.range.upperBound <= length {
            let range = NSRange(location: mark.range.lowerBound, length: mark.range.count)
            styled.addAttributes([.backgroundColor: NSColor(Color.lichen), .foregroundColor: NSColor(Color.evergreen)], range: range)
        }
        return (try? AttributedString(styled, including: \.appKit)) ?? AttributedString(text)
    }
}

private struct TablePreview: View {
    let columns: [String]
    let rows: [[String]]
    let rowCount: Int
    private let widths: [CGFloat]
    private let cellMarks: [Int: [Int: [Mark]]]

    init(columns: [String], rows: [[String]], rowCount: Int, marks: [TableMark]) {
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        widths = columns.indices.map { column in
            let longest = max(columns[column].count, rows.prefix(100).compactMap { column < $0.count ? $0[column].count : nil }.max() ?? 0)
            return min(240, max(100, CGFloat(longest * 8 + 12)))
        }
        var grouped: [Int: [Int: [Mark]]] = [:]
        for mark in marks { grouped[mark.row, default: [:]][mark.column, default: []].append(Mark(range: mark.range, entity: mark.entity)) }
        cellMarks = grouped
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(columns.indices, id: \.self) { column in
                            Text(columns[column])
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.slate)
                                .frame(width: widths[column], alignment: .leading)
                                .padding(.trailing, 24)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 36)
                    .background(Color.snow)
                    .overlay(alignment: .bottom) { Divider().overlay(Color.line) }
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
                                .overlay(alignment: .bottom) { Divider().overlay(Color.fog) }
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
    @ViewBuilder private func cell(row: Int, column: Int) -> some View {
        let value = column < rows[row].count ? rows[row][column] : ""
        if value.contains("\n") || value.contains("\r") {
            Text((value.components(separatedBy: .newlines).first ?? "") + " …").help(value)
        } else {
            Text(ResultView.highlighted(value, cellMarks[row]?[column] ?? [])).help(value)
        }
    }

}
