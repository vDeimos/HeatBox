// Controls.swift: the buttons and small parts used on more than one screen.
//
// View-local values (is the pointer over this button) use the `State` struct
// directly, never the `@State` attribute.

import Engine
import SwiftUI

struct PillButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, danger }
    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.palette) private var p
        @Environment(\.isEnabled) private var enabled
        private let hovering = State(initialValue: false)

        var body: some View {
            configuration.label
                .font(p.font(13, kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(kind == .primary ? p.onFill : (kind == .danger ? p.bad : p.text))
                .background(kind == .primary ? p.fill : p.control)
                .cornerRadius(7)
                .focusShape(radius: 7)
                .brightness(hovering.wrappedValue && enabled ? (p.dark ? 0.06 : -0.04) : 0)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .onHover { hovering.wrappedValue = $0 }
                .accessibilityElement(children: .combine)
        }
    }
}

/// Lets Tab reach a group of rows or tiles as it reaches a list, whether or
/// not "Keyboard navigation" is on in System Settings; the arrow keys then
/// move inside it (`onMoveCommand`). Where the chosen item carries its own
/// mark, the ring round the whole group is left out on the macOS versions
/// that let an app do that (macOS 14 and later).
private struct KeyboardList: ViewModifier {
    let enabled: Bool
    let ownMark: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusable(enabled, interactions: .edit).focusEffectDisabled(ownMark)
        } else {
            content.focusable(enabled)
        }
    }
}

extension View {
    func keyboardList(enabled: Bool = true, ownMark: Bool = false) -> some View {
        modifier(KeyboardList(enabled: enabled, ownMark: ownMark))
    }
}

/// A small label such as "Done", "Failed" or "Last used".
struct Tag: View {
    let text: String
    /// A mark in front of the word, such as a tick.
    var symbol: String?
    var fill: Color
    var foreground: Color
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(p.font(10, .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(p.font(11, .medium))
        }
        .foregroundColor(foreground)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(fill)
        .clipShape(Capsule())
    }
}

/// The rounded outline shared by every group of rows.
private struct GroupChrome: ViewModifier {
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content
            .background(p.surface0)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.outline, lineWidth: 1))
            .shadow(color: Color.black.opacity(p.dark ? 0 : 0.04), radius: 1, x: 0, y: 1)
    }
}

/// The heading that sits above a group.
struct GroupHeader: View {
    let title: String
    @Environment(\.palette) private var p

    var body: some View {
        Text(title)
            .font(p.font(13, .semibold))
            .foregroundColor(p.text)
            .padding(.horizontal, 14)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group whose rows run edge to edge, separated by `RowDivider`.
struct Grouped<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                GroupHeader(title: title)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupChrome()
        }
    }
}

/// The hairline between two rows of a group.
struct RowDivider: View {
    @Environment(\.palette) private var p

    var body: some View {
        Rectangle()
            .fill(p.separator)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A padded group of related controls, with its heading above it.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                GroupHeader(title: title)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupChrome()
        }
    }
}

/// The outline of a box for typing in.
private struct FieldChrome: ViewModifier {
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content
            .background(p.field)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(p.fieldBorder, lineWidth: 1))
    }
}

extension View {
    /// The shape of the ring macOS draws round a control the keyboard is on
    /// (System Settings > Keyboard > Keyboard navigation), so the ring follows
    /// the control's own corners and stays clear of the window's edge.
    func focusShape(radius: CGFloat, inset: CGFloat = 0) -> some View {
        contentShape(.focusEffect, RoundedRectangle(cornerRadius: radius, style: .continuous).inset(by: inset))
    }

    func fieldChrome() -> some View {
        modifier(FieldChrome())
    }

    /// The panel look used by groups and banners.
    func groupChrome() -> some View {
        modifier(GroupChrome())
    }
}

/// A small line of explanation under a group.
struct Caption: View {
    let text: String
    @Environment(\.palette) private var p

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(p.font(12))
            .foregroundColor(p.subtext)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
    }
}

/// A row with a sentence on the left and an on/off switch on the right.
struct SwitchRow: View {
    let title: String
    var detail: String?
    /// A picture in front of the sentence.
    var symbol: String?
    @Binding var isOn: Bool
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                RowSymbol(name: symbol)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(p.font(13))
                    .foregroundColor(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(p.fill)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The small picture at the start of a row.
struct RowSymbol: View {
    let name: String
    @Environment(\.palette) private var p

    var body: some View {
        Image(systemName: name)
            .font(p.font(14))
            .foregroundColor(p.accent)
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}

/// A row with a label on the left and a control on the right.
struct ControlRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: () -> Control
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(p.font(13))
                .foregroundColor(p.text)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A row of mutually exclusive options, such as Dark / Light / Match the system.
struct Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button(option.label) { selection = option.value }
                    .buttonStyle(.plain)
                    .font(p.font(13, on ? .semibold : .regular))
                    .foregroundColor(on ? p.onFill : p.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(on ? p.fill : Color.clear)
                    .cornerRadius(6)
                    .focusShape(radius: 6)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(p.control)
        .cornerRadius(8)
    }
}

/// The round mark at the start of a row where one of several is picked.
struct RadioMark: View {
    let on: Bool
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            if on {
                Circle().fill(p.fill)
                Circle().fill(Color.white).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(p.subtext, lineWidth: 1.5)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// One version of a video, with its explanation. Sits inside a `Grouped`.
struct ChoiceRow: View {
    let choice: Choice
    let selected: Bool
    let isLastChoice: Bool
    let action: () -> Void
    @Environment(\.palette) private var p
    private let hovering = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                RadioMark(on: selected)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(choice.title)
                            .font(p.font(13, .semibold))
                            .foregroundColor(p.text)
                        if isLastChoice {
                            Tag(text: "Last used", fill: p.control, foreground: p.text)
                        }
                    }
                    Text(choice.explanation)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                if !choice.badge.isEmpty {
                    Text(choice.badge)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .lineLimit(1)
                }
                Text(choice.size)
                    .font(p.font(12).monospacedDigit())
                    .foregroundColor(p.text)
                    .lineLimit(1)
                    .frame(minWidth: 84, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? p.control.opacity(0.55) : (hovering.wrappedValue ? p.control.opacity(0.3) : Color.clear))
            .contentShape(Rectangle())
            .focusShape(radius: 7, inset: 3)
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(choice.title), \(choice.badge), \(choice.size). \(choice.explanation)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }
}
