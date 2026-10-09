// Theme.swift: every colour and text size in the app is defined here, once.
//
// The look follows macOS: quiet warm neutrals taken from HeatBox's artwork
// (charcoal, cream), one accent colour, hairline separators.
// There is a dark and a light set; "Match the system" picks between them.

import AppKit
import Engine
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

extension ThemeChoice {
    var label: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .system: return "Match the system"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    /// The same choice for AppKit, so every window, sheet and alert agrees.
    var appearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

extension AccentChoice {
    var label: String {
        switch self {
        case .ember: return "Ember"
        case .blue: return "Blue"
        case .peach: return "Orange"
        case .green: return "Green"
        case .pink: return "Pink"
        case .mauve: return "Purple"
        case .teal: return "Teal"
        }
    }

    /// The accent as a foreground colour: bright on the dark theme, deep on
    /// the light one, so icons and marks stay readable in both.
    func color(dark: Bool) -> Color {
        switch self {
        case .ember: return Color(hex: dark ? 0xe8892a : 0x9a4a0c)
        case .blue: return Color(hex: dark ? 0x4da3ff : 0x0060d0)
        case .peach: return Color(hex: dark ? 0xff9f0a : 0xa85400)
        case .green: return Color(hex: dark ? 0x32d74b : 0x1a6b32)
        case .pink: return Color(hex: dark ? 0xff6fa5 : 0xb5235f)
        case .mauve: return Color(hex: dark ? 0xbf8cff : 0x7a35b0)
        case .teal: return Color(hex: dark ? 0x40c8d8 : 0x0b6570)
        }
    }

    /// The accent as a fill behind white text, the same in both themes.
    var fill: Color {
        switch self {
        // Never the artwork's own orange (#DD7B1B): white on it is only 3.0:1.
        case .ember: return Color(hex: 0xa84f0f)
        case .blue: return Color(hex: 0x0a6fe0)
        case .peach: return Color(hex: 0xb85c00)
        case .green: return Color(hex: 0x1f7a3a)
        case .pink: return Color(hex: 0xc2255c)
        case .mauve: return Color(hex: 0x8944ab)
        case .teal: return Color(hex: 0x0e7480)
        }
    }
}

struct Palette {
    var dark: Bool
    /// The window behind everything.
    var base: Color
    /// The sidebar panel.
    var mantle: Color
    /// A group of rows.
    var surface0: Color
    /// A solid neutral for placeholders and unselected marks.
    var surface1: Color
    var text: Color
    var subtext: Color
    /// The accent as a foreground colour.
    var accent: Color
    /// The accent as a fill; text on it uses `onFill`.
    var fill: Color
    var onFill: Color
    var good: Color
    var bad: Color
    var warn: Color
    /// The artwork's cardboard tan, used sparingly for tags.
    var tan: Color
    /// Hairlines between rows.
    var separator: Color
    /// The outline of a group and of the sidebar.
    var outline: Color
    /// The fill of an ordinary button.
    var control: Color
    /// The selected part of a segmented control.
    var raised: Color
    var field: Color
    var fieldBorder: Color
    var scale: CGFloat

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }

    func mono(_ size: CGFloat) -> Font {
        .system(size: size * scale, design: .monospaced)
    }

    /// A soft tint of a colour, for a label such as "Done" or "Failed".
    func wash(_ color: Color) -> Color {
        color.opacity(dark ? 0.20 : 0.13)
    }

    static func make(dark: Bool, accent: AccentChoice, large: Bool) -> Palette {
        if dark {
            return Palette(dark: true,
                           base: Color(hex: 0x1e2222), mantle: Color(hex: 0x252a2a),
                           surface0: Color(hex: 0x2a3030), surface1: Color(hex: 0x3a3a3c),
                           text: Color(hex: 0xf5efe6), subtext: Color(hex: 0xa9a39a),
                           accent: accent.color(dark: true), fill: accent.fill, onFill: Color.white,
                           good: Color(hex: 0x32d74b), bad: Color(hex: 0xff6961), warn: Color(hex: 0xff9f0a),
                           tan: Color(hex: 0xbf8e4f),
                           separator: Color.white.opacity(0.09), outline: Color.white.opacity(0.07),
                           control: Color.white.opacity(0.13), raised: Color(hex: 0x636366),
                           field: Color.white.opacity(0.06), fieldBorder: Color.white.opacity(0.16),
                           scale: large ? 1.18 : 1)
        }
        return Palette(dark: false,
                       base: Color(hex: 0xf7f3ec), mantle: Color(hex: 0xfbf8f3),
                       surface0: Color.white, surface1: Color(hex: 0xe3e3e8),
                       text: Color(hex: 0x1e2222), subtext: Color(hex: 0x6b655c),
                       accent: accent.color(dark: false), fill: accent.fill, onFill: Color.white,
                       good: Color(hex: 0x1a6b32), bad: Color(hex: 0xc4201c), warn: Color(hex: 0x9a4f00),
                       tan: Color(hex: 0x7a5a2e),
                       separator: Color.black.opacity(0.08), outline: Color.black.opacity(0.08),
                       control: Color.black.opacity(0.07), raised: Color.white,
                       field: Color.white, fieldBorder: Color.black.opacity(0.20),
                       scale: large ? 1.18 : 1)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.make(dark: true, accent: .ember, large: false)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Gives everything inside it the colours the person chose in Settings.
/// Each window wraps its content in one of these.
struct Themed<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ObservedObject private var settings = AppModel.shared.settings
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let theme = settings.value.theme
        let dark = theme == .dark || (theme == .system && systemScheme == .dark)
        content()
            .environment(\.palette, Palette.make(dark: dark, accent: settings.value.accent,
                                                 large: settings.value.largeText))
    }
}
