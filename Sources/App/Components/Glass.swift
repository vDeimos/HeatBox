// Glass.swift: macOS 26's Liquid Glass, and what stands in for it before.
//
// Glass is for what floats above the content: the bar under the Download
// screen, the command bar, the tour, a label over a picture. Groups of rows
// and everything that is read stay solid. On macOS 13 to 15 the same parts
// are drawn with the palette's own colours, as they were before.

import AppKit
import SwiftUI

enum Chrome {
    /// Whether this launch draws glass. `--no-glass` shows the app the way
    /// macOS 13 to 15 draw it, to check that look on a newer Mac.
    static let glass: Bool = {
        if Launch.arguments.contains("--no-glass") { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }()
}

/// A panel that floats over the window: glass where there is glass, and the
/// palette's group colour with an outline where there is not.
private struct FloatingPanel: ViewModifier {
    var radius: CGFloat
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), Chrome.glass {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(p.surface0)
                .clipShape(shape)
                .overlay(shape.strokeBorder(p.outline, lineWidth: 1))
        }
    }
}

/// A small label over a picture, such as a video's length.
private struct FloatingBadge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), Chrome.glass {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Color.black.opacity(0.72)).clipShape(Capsule())
        }
    }
}

extension View {
    func floatingPanel(radius: CGFloat = 12) -> some View {
        modifier(FloatingPanel(radius: radius))
    }

    func floatingBadge() -> some View {
        modifier(FloatingBadge())
    }
}

/// A video's length in the corner of its picture.
struct DurationBadge: View {
    let text: String
    @Environment(\.palette) private var p

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(p.font(11, .semibold).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .floatingBadge()
                .environment(\.colorScheme, .dark)
                .padding(5)
                .accessibilityHidden(true)
        }
    }
}
