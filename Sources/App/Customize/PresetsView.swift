// PresetsView.swift: the presets menu, and the sheet where the person's own
// presets are renamed, deleted, exported and imported.
//
// What a preset may hold, what an import refuses and what a file looks like
// are the engine's (`PresetShelf`, `PresetExchange`); this file asks for a
// name or a file and shows the result.

import AppKit
import Engine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PresetsModel: ObservableObject {
    @Published private(set) var shelf = PresetShelf()
    /// One or two sentences about the last import or a refused name.
    @Published var notice: String?

    private let store: PresetStore

    init(store: PresetStore) {
        self.store = store
        shelf = PresetShelf(store.load())
    }

    /// Reads the file again, after the one-time move from the older apps wrote it.
    func reload() { shelf = PresetShelf(store.load()) }

    private func change(_ edit: (inout PresetShelf) -> Void) {
        var copy = shelf
        edit(&copy)
        guard copy != shelf else { return }
        shelf = copy
        try? store.save(copy.presets)
    }

    private func askForName(title: String, text: String, suggestion: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { notice = Messages.presetNameEmpty }
        return name.isEmpty ? nil : name
    }

    /// Saves the recipe on the Download screen under a name the person types.
    func saveCurrent(from download: DownloadModel) {
        guard let recipe = download.currentRecipe, let draft = download.draft else { return }
        // A preset of the person's own is offered its own name, to save over it.
        let own = draft.custom?.presetID.flatMap { shelf.preset(id: $0) }
        guard let name = askForName(title: "Save as a preset",
                                    text: "The preset keeps every setting in Customize except the clip. Saving under the name of one of your presets replaces it.",
                                    suggestion: own?.name ?? "", button: "Save") else { return }
        var saved: Preset?
        change { saved = $0.save(name: name, recipe: recipe) }
        if let saved { download.apply(saved) }
        notice = nil
    }

    func rename(_ preset: Preset) {
        guard let name = askForName(title: "Rename \"\(preset.name)\"", text: "", suggestion: preset.name, button: "Rename") else { return }
        var done = false
        change { done = $0.rename(id: preset.id, to: name) }
        notice = done || name == preset.name ? nil : Messages.presetNameTaken
    }

    func delete(_ preset: Preset) {
        let alert = NSAlert()
        alert.messageText = "Delete the preset \"\(preset.name)\"?"
        alert.informativeText = "Downloads already in the Queue keep their settings."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        change { $0.remove(id: preset.id) }
    }

    func export(_ presets: [Preset]) {
        guard !presets.isEmpty, let data = try? PresetExchange.export(presets) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetExchange.suggestedFileName(for: presets)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            notice = nil
        } catch {
            notice = "The file couldn't be saved there. Choose another folder."
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let read = PresetExchange.read(data) else {
            notice = Messages.presetFileUnreadable
            return
        }
        change { $0.add(imported: read.presets) }
        notice = read.summary
    }
}

/// The menu of presets: Studio's nine, the person's own, and what can be done with them.
struct PresetsMenu: View {
    @ObservedObject var model: DownloadModel
    var title = "Presets"
    @ObservedObject private var presets = AppModel.shared.presets
    @Environment(\.palette) private var p

    var body: some View {
        Menu {
            Section("Ready-made") {
                ForEach(PresetCatalog.advanced) { preset in
                    Button(preset.name) { model.apply(preset) }
                }
            }
            if !presets.shelf.presets.isEmpty {
                Section("Yours") {
                    ForEach(presets.shelf.presets) { preset in
                        Button(preset.name) { model.apply(preset) }
                    }
                }
            }
            Divider()
            Button("Save Current Settings as a Preset…") { presets.saveCurrent(from: model) }
                .disabled(model.currentRecipe == nil || model.hasErrors)
            Button("Manage Presets…") { model.showPresets() }
        } label: {
            Text(title)
                .font(p.font(13, .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Presets")
    }
}

/// The person's own presets, one per row.
struct ManagePresetsView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject private var presets = AppModel.shared.presets
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your presets")
                    .font(p.font(15, .semibold))
                    .foregroundColor(p.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            RowDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice = presets.notice {
                        Text(notice)
                            .font(p.font(12))
                            .foregroundColor(p.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .groupChrome()
                            .accessibilityLabel("Result")
                            .accessibilityValue(notice)
                    }
                    if presets.shelf.presets.isEmpty {
                        Text("You have no presets of your own yet. Open Customize, set things as you like them, and choose Save as Preset. A presets file from someone else can be imported below.")
                            .font(p.font(13))
                            .foregroundColor(p.subtext)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Grouped {
                            ForEach(Array(presets.shelf.presets.enumerated()), id: \.element.id) { pair in
                                if pair.offset > 0 { RowDivider() }
                                row(pair.element)
                            }
                        }
                    }
                }
                .padding(20)
            }
            RowDivider()
            HStack(spacing: 10) {
                Button("Import…") { presets.importFile() }
                    .buttonStyle(PillButtonStyle())
                Button("Export All…") { presets.export(presets.shelf.presets) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(presets.shelf.presets.isEmpty)
                Spacer()
                Button("Done") { model.closePanel() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .frame(width: 600, height: 480)
        .background(p.base)
    }

    private func row(_ preset: Preset) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(p.font(13, .semibold))
                    .foregroundColor(p.text)
                    .lineLimit(1)
                Text(preset.recipe.mode.label)
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
            }
            Spacer(minLength: 8)
            Button("Rename…") { presets.rename(preset) }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Rename \(preset.name)")
            Button("Export…") { presets.export([preset]) }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Export \(preset.name)")
            Button("Delete") { presets.delete(preset) }
                .buttonStyle(PillButtonStyle(kind: .danger))
                .accessibilityLabel("Delete \(preset.name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
