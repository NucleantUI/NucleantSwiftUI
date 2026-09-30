//
//  ControlSupport.swift
//  NucleantUI
//
//  What `Toggle`, `Slider`, `Stepper` and `Picker` have in common:
//  `.labelsHidden()`, and the checkmark the checkbox and the pickers draw.
//

private struct LabelsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the controls in this subtree leave their labels out.
    var labelsHidden: Bool {
        get { self[LabelsHiddenKey.self] }
        set { self[LabelsHiddenKey.self] = newValue }
    }
}

extension View {
    /// Hides the labels of the controls within this view — a toggle shows
    /// only its switch, a picker only its choices.
    ///
    /// ```swift
    /// Toggle("Loop", isOn: $isLooping)
    ///     .labelsHidden()
    /// ```
    public func labelsHidden() -> some View {
        environment(\.labelsHidden, true)
    }
}

/// A tick, drawn to fill its frame. Stroked, not filled: the bundled face
/// has no "✓" of its own.
@View
struct _ControlCheckmark: Shape {
    func path(in rect: Rect) -> Path {
        var path = Path()
        path.move(to: Point(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.52))
        path.addLine(to: Point(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.76))
        path.addLine(to: Point(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.26))
        return path
    }
}

/// The track colour of a control that is off or empty — a switch turned
/// off, the unfilled part of a slider.
let controlTrackColor = Color.dynamic(light: Color(white: 0.84), dark: Color(white: 0.28))
