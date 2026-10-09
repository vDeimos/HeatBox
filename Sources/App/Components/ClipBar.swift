// ClipBar.swift: choosing part of a video, by dragging or by typing.

import AppKit
import Engine
import SwiftUI

/// A bar the length of the video with a handle at each end of the clip.
struct ClipBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Chapter start times, drawn as marks the handles snap to.
    var chapters: [Double] = []
    @Environment(\.palette) private var p

    private let knob: CGFloat = 18

    private func snapped(_ value: Double) -> Double {
        let reach = duration * 0.012
        if let mark = chapters.min(by: { abs($0 - value) < abs($1 - value) }), abs(mark - value) <= reach {
            return mark
        }
        return value.rounded()
    }

    private func handle(_ value: Binding<Double>, lower: Double, upper: Double, width: CGFloat, label: String) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: knob, height: knob)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
            .contentShape(Rectangle().inset(by: -8))
            .offset(x: CGFloat(value.wrappedValue / duration) * width)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("clipbar")).onChanged { drag in
                    let raw = Double((drag.location.x - knob / 2) / width) * duration
                    value.wrappedValue = min(max(snapped(raw), lower), upper)
                }
            )
            .focusable()
            .onMoveCommand { direction in
                let step: Double = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
                switch direction {
                case .left, .down: value.wrappedValue = max(value.wrappedValue - step, lower)
                case .right, .up: value.wrappedValue = min(value.wrappedValue + step, upper)
                default: break
                }
            }
            .accessibilityLabel(label)
            .accessibilityValue(TimeText.clock(value.wrappedValue))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value.wrappedValue = min(value.wrappedValue + 1, upper)
                case .decrement: value.wrappedValue = max(value.wrappedValue - 1, lower)
                @unknown default: break
                }
            }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - knob, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(p.control)
                    .frame(height: 4)
                    .padding(.horizontal, knob / 2)
                Capsule()
                    .fill(p.fill)
                    .frame(width: max(CGFloat((end - start) / duration) * width, 0), height: 4)
                    .offset(x: knob / 2 + CGFloat(start / duration) * width)
                ForEach(chapters, id: \.self) { mark in
                    Rectangle()
                        .fill(p.subtext)
                        .frame(width: 1, height: 10)
                        .offset(x: knob / 2 + CGFloat(mark / duration) * width - 0.5)
                        .accessibilityHidden(true)
                }
                handle($start, lower: 0, upper: max(end - 1, 0), width: width,
                       label: "Clip start. Drag, or use the arrow keys")
                handle($end, lower: min(start + 1, duration), upper: duration, width: width,
                       label: "Clip end. Drag, or use the arrow keys")
            }
            .frame(height: 28)
            .coordinateSpace(name: "clipbar")
        }
        .frame(height: 28)
    }
}

/// A box for typing a time such as 2:45.
struct TimeField: View {
    let label: String
    @Binding var seconds: Double
    let lower: Double
    let upper: Double
    @Environment(\.palette) private var p
    private let text = State(initialValue: "")

    private func commit() {
        if let typed = TimeText.seconds(from: text.wrappedValue) {
            seconds = min(max(typed, lower), upper)
        }
        text.wrappedValue = TimeText.clock(seconds)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(p.font(13))
                .foregroundColor(p.text)
            TextField("0:00", text: text.projectedValue)
                .textFieldStyle(.plain)
                .font(p.font(13).monospacedDigit())
                .foregroundColor(p.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 76)
                .fieldChrome()
                .onSubmit { commit() }
                .accessibilityLabel(label)
        }
        .onAppear { text.wrappedValue = TimeText.clock(seconds) }
        .onChange(of: seconds) { newValue in
            text.wrappedValue = TimeText.clock(newValue)
        }
    }
}

/// The bar and both time boxes together, with the clip's length.
struct ClipControls: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var chapters: [Double] = []
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ClipBar(duration: duration, start: $start, end: $end, chapters: chapters)
            HStack(alignment: .center, spacing: 16) {
                TimeField(label: "Start", seconds: $start, lower: 0, upper: max(end - 1, 0))
                TimeField(label: "End", seconds: $end, lower: min(start + 1, duration), upper: duration)
                Spacer(minLength: 8)
                Text("Clip length \(TimeText.clock(max(end - start, 0)))")
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
            }
            Text("Type a time and press Return, or drag a handle. With a handle selected, the arrow keys move it; hold Shift for ten seconds at a time.")
                .font(p.font(11))
                .foregroundColor(p.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
