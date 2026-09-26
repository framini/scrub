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
            Button(finished.copied ? "Copied" : "Copy") { model.copy() }.buttonStyle(SecondaryButton())
            Button(finished.savedAs == nil ? "Save…" : "Save again…") { model.save() }.buttonStyle(PrimaryButton())
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
            Spacer()
            Text("Press esc to clear").foregroundStyle(Color.slate)
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
