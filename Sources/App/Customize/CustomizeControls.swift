// CustomizeControls.swift: the rows the Customize panel is made of.
//
// Each row draws one field of a recipe and hands a change straight back
// through its binding; none of them decides anything.

import Engine
import SwiftUI

/// A label with a pop-up of choices on the right.
struct PickRow<Value: Hashable>: View {
    let label: String
    var detail: String?
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(p.font(13))
                    .foregroundColor(p.text)
                if let detail {
                    Text(detail)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Picker(label, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(label)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

extension PickRow where Value: CaseIterable {
    /// Every case of a choice, each with its own words.
    init(_ label: String, detail: String? = nil, selection: Binding<Value>, name: (Value) -> String) {
        self.init(label: label, detail: detail, options: Value.allCases.map { (value: $0, label: name($0)) }, selection: selection)
    }
}

/// A label with a box to type in. With `wide`, the box sits under the label.
struct TextRow: View {
    let label: String
    var detail: String?
    var placeholder = ""
    var wide = false
    var mono = false
    @Binding var text: String
    @Environment(\.palette) private var p

    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? p.mono(12) : p.font(13))
            .foregroundColor(p.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .fieldChrome()
            .accessibilityLabel(label)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(p.font(13))
                .foregroundColor(p.text)
            if let detail {
                Text(detail)
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 8) {
                    words
                    field
                }
            } else {
                HStack(spacing: 12) {
                    words
                    Spacer(minLength: 12)
                    field.frame(width: 190)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A whole number with a stepper.
struct NumberRow: View {
    let label: String
    var detail: String?
    let range: ClosedRange<Int>
    var unit = ""
    @Binding var value: Int
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(p.font(13))
                    .foregroundColor(p.text)
                if let detail {
                    Text(detail)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                .font(p.font(13).monospacedDigit())
                .foregroundColor(p.text)
            Stepper(label, value: $value, in: range)
                .labelsHidden()
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A number with a fraction, typed.
struct DecimalRow: View {
    let label: String
    var detail: String?
    var unit = ""
    @Binding var value: Double
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(p.font(13))
                    .foregroundColor(p.text)
                if let detail {
                    Text(detail)
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            TextField("0", value: $value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(p.font(13).monospacedDigit())
                .foregroundColor(p.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 80)
                .fieldChrome()
                .accessibilityLabel(label)
            if !unit.isEmpty {
                Text(unit)
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A sentence inside a group, for something that needs saying where it applies.
struct NoteRow: View {
    let text: String
    var warning = false
    @Environment(\.palette) private var p

    var body: some View {
        Text(text)
            .font(p.font(12))
            .foregroundColor(warning ? p.warn : p.subtext)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
    }
}

/// Rows with a hairline between each two of them.
struct Rows: View {
    let rows: [AnyView]

    init(_ rows: [AnyView?]) {
        self.rows = rows.compactMap { $0 }
    }

    var body: some View {
        Grouped {
            ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 { RowDivider() }
                pair.element
            }
        }
    }
}

extension View {
    /// The row, or nothing when it does not apply.
    func row(if applies: Bool = true) -> AnyView? {
        applies ? AnyView(self) : nil
    }
}
