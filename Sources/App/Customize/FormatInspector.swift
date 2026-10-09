// FormatInspector.swift: every version the site offers, to pick from by hand.
//
// The table and what the picked rows come to are the engine's
// (`FormatCatalog`, built from the same look-up as the explained choices).

import Engine
import SwiftUI

struct FormatInspector: View {
    @ObservedObject var model: DownloadModel
    @Environment(\.palette) private var p
    private let filter = State(initialValue: FormatCatalog.Filter.all)

    private var catalog: FormatCatalog? { model.draft?.media.map(FormatCatalog.init) }

    private func label(_ filter: FormatCatalog.Filter) -> String {
        switch filter {
        case .all: return "All"
        case .video: return "Video"
        case .audio: return "Audio"
        case .combined: return "Both in one"
        }
    }

    private let columns: [(title: String, width: CGFloat, text: (FormatCatalog.Row) -> String)] = [
        ("ID", 70, { $0.id }), ("Kind", 52, { $0.kind }), ("Type", 44, { $0.ext }), ("Picture", 86, { $0.resolution }),
        ("fps", 30, { $0.fps }), ("Video", 100, { $0.videoCodec }), ("Audio", 84, { $0.audioCodec }),
        ("Bitrate", 56, { $0.bitrate }), ("Size", 70, { $0.size }),
    ]

    var body: some View {
        let rows = catalog?.rows(filter.wrappedValue) ?? []
        let selector = catalog?.selector(for: model.formatPicks)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("All formats")
                    .font(p.font(15, .semibold))
                    .foregroundColor(p.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Segmented(options: FormatCatalog.Filter.allCases.map { (value: $0, label: label($0)) },
                          selection: filter.projectedValue)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            RowDivider()
            HStack(spacing: 8) {
                Color.clear.frame(width: 16)
                ForEach(columns, id: \.title) { column in
                    Text(column.title).frame(width: column.width, alignment: .leading)
                }
                Text("Note").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(p.font(11, .semibold))
            .foregroundColor(p.subtext)
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            RowDivider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        let on = model.formatPicks.contains(row.id)
                        Button {
                            if on { model.formatPicks.remove(row.id) } else { model.formatPicks.insert(row.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(on ? p.accent : p.subtext)
                                    .frame(width: 16)
                                    .accessibilityHidden(true)
                                ForEach(columns, id: \.title) { column in
                                    Text(column.text(row)).frame(width: column.width, alignment: .leading)
                                }
                                Text(row.note).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(p.mono(11))
                            .foregroundColor(p.text)
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)
                            .background(on ? p.control : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Format \(row.id), \(row.kind), \(row.resolution), \(row.size)")
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
            }
            RowDivider()
            HStack(spacing: 10) {
                Text(selector.map { "Will download: \($0)" }
                     ?? "Pick one video row and one audio row, or a single row that has both.")
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .lineLimit(2)
                    .accessibilityLabel("Selection")
                    .accessibilityValue(selector ?? "")
                Spacer(minLength: 12)
                Button("Cancel") { model.closePanel() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Use These") { model.useFormats() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(selector == nil)
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .frame(width: 860, height: 560)
        .background(p.base)
    }
}
