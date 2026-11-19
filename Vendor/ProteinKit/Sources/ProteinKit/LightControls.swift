import SwiftUI

/// An on/off switch drawn by SwiftUI itself, looking like the small system one. The system switch
/// (macOS 26 glass) costs ~100 MB of graphics memory for a moment on first draw and keeps ~6 MB
/// (measured in MeetRec and Genius Typer).
///
/// `spreads`: the label on the left and the switch at the right edge, as in a settings form row.
public struct LightSwitchStyle: ToggleStyle {
    private let spreads: Bool

    public init(spreads: Bool = false) {
        self.spreads = spreads
    }

    public func makeBody(configuration: Configuration) -> some View {
        LightSwitchBody(configuration: configuration, spreads: spreads)
    }
}

private struct LightSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    let spreads: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            configuration.label
            if spreads {
                Spacer(minLength: 8)
            }
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.15))
                .frame(width: 30, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .padding(1.5)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? Text("Вкл.", bundle: .module) : Text("Выкл.", bundle: .module))
                .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

/// A slider drawn by SwiftUI, for the same reason: the system one (macOS 26 glass) took ~100 MB
/// for a moment the first time a page showed it.
public struct LightSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    /// True when a drag starts, false when it ends (e.g. one undo step per drag).
    private let onEditingChanged: (Bool) -> Void

    @State private var dragging = false

    static let knob: CGFloat = 16

    public init(value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
    }

    /// The value under `x` (points from the slider's left edge) on a slider `width` wide: the knob's
    /// centre follows the pointer, snapped to `step` and kept in `range`.
    static func value(atX x: CGFloat, width: CGFloat, range: ClosedRange<Double>, step: Double) -> Double {
        let track = max(width - knob, 1)
        let raw = range.lowerBound + Double((x - knob / 2) / track) * (range.upperBound - range.lowerBound)
        return clamp((raw / step).rounded() * step, to: range)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public var body: some View {
        GeometryReader { geometry in
            let knob = Self.knob
            let track = max(geometry.size.width - knob, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? CGFloat((Self.clamp(value, to: range) - range.lowerBound) / span) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: knob / 2 + track * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: track * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if !dragging {
                    dragging = true
                    onEditingChanged(true)
                }
                value = Self.value(atX: drag.location.x, width: geometry.size.width, range: range, step: step)
            }.onEnded { _ in
                dragging = false
                onEditingChanged(false)
            })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            value = Self.clamp(value + (direction == .increment ? step : -step), to: range)
        }
    }
}
