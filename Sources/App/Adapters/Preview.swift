// Preview.swift: the Finder-style preview panel that the spacebar opens.
import AppKit
import QuickLookUI

final class PreviewCenter: NSObject, QLPreviewPanelDataSource {
    static let shared = PreviewCenter()
    private var items: [NSURL] = []

    /// Formats macOS cannot preview; these open in the player instead.
    static let unpreviewable: Set<String> = ["webm", "mkv", "avi", "flv", "ogv", "wmv"]

    @MainActor
    func show(_ path: String) {
        if Self.unpreviewable.contains((path as NSString).pathExtension.lowercased()) {
            Opener.play(path)
            return
        }
        items = [NSURL(fileURLWithPath: path)]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] }
}
