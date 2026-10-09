// CustomizeView.swift: the Customize panel, a sheet over the Download screen.
//
// It shows the recipe that will be downloaded, group by group, with the
// exact command underneath. Nothing here is remembered unless it is saved
// as a preset (plan Rule 6); someone who never opens it sees no difference.

import AppKit
import Engine
import SwiftUI

struct CustomizeView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject private var presets = AppModel.shared.presets
    @Environment(\.palette) private var p
    private let category = State(initialValue: CustomizeCategory.format)
    private let copied = State(initialValue: false)

    private var issues: [RecipeIssue] { model.issues }

    private func count(in category: CustomizeCategory) -> Int {
        issues.filter { $0.severity == .error && category.fields.contains($0.field) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RowDivider()
            HStack(spacing: 0) {
                categories
                Rectangle().fill(p.separator).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        problems
                        CustomizeCategoryView(category: category.wrappedValue, model: model)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            RowDivider()
            CommandPreviewView(preview: model.preview, copied: copied)
            RowDivider()
            footer
        }
        .frame(width: 820, height: 640)
        .background(p.base)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize")
                    .font(p.font(15, .semibold))
                    .foregroundColor(p.text)
                    .accessibilityAddTraits(.isHeader)
                Text(model.draft?.custom?.name ?? "")
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            PresetsMenu(model: model, title: "Presets")
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CustomizeCategory.allCases) { item in
                let on = item == category.wrappedValue
                let errors = count(in: item)
                Button {
                    category.wrappedValue = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .foregroundColor(p.accent)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(item.label)
                        Spacer(minLength: 4)
                        if errors > 0 {
                            Circle().fill(p.bad).frame(width: 7, height: 7)
                                .accessibilityLabel("Needs attention")
                        }
                    }
                    .font(p.font(13, on ? .semibold : .medium))
                    .foregroundColor(p.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(on ? p.control : Color.clear)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 210)
        .background(p.mantle)
    }

    /// What stops the download, and what will not do what it seems to.
    @ViewBuilder
    private var problems: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(issues.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: pair.element.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(pair.element.severity == .error ? p.bad : p.warn)
                            .accessibilityHidden(true)
                        Text(pair.element.message)
                            .font(p.font(12))
                            .foregroundColor(p.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupChrome()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Save as Preset…") { presets.saveCurrent(from: model) }
                .buttonStyle(PillButtonStyle())
                .disabled(model.hasErrors)
            Button("Back to the Explained Choices") {
                model.dropCustom()
                model.panel = nil
            }
            .buttonStyle(PillButtonStyle())
            Spacer(minLength: 12)
            Text("Changes apply to this download only, unless you save them as a preset.")
                .font(p.font(11))
                .foregroundColor(p.subtext)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Button("Done") { model.panel = nil }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }
}

/// The exact command, to read and to copy.
struct CommandPreviewView: View {
    let preview: CommandPreview
    let copied: State<Bool>
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Command")
                    .font(p.font(12, .semibold))
                    .foregroundColor(p.text)
                Spacer()
                if copied.wrappedValue {
                    Text("Copied")
                        .font(p.font(11))
                        .foregroundColor(p.good)
                }
                Button("Copy") {
                    Opener.copy(preview.command)
                    copied.wrappedValue = true
                }
                .buttonStyle(PillButtonStyle())
                .disabled(preview.command.isEmpty)
                .accessibilityLabel("Copy the command")
            }
            ScrollView {
                Text(preview.command.isEmpty ? (preview.problem ?? "") : preview.command)
                    .font(p.mono(11))
                    .foregroundColor(preview.command.isEmpty ? p.bad : p.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Command preview")
                    .accessibilityValue(preview.command.isEmpty ? (preview.problem ?? "") : preview.command)
            }
            .frame(height: 64)
            .padding(8)
            .fieldChrome()
            if !preview.command.isEmpty {
                Text(preview.notes.joined(separator: " "))
                    .font(p.font(11))
                    .foregroundColor(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .onChange(of: preview.command) { _ in copied.wrappedValue = false }
    }
}
