//
//  Button.swift
//  NucleantSwiftUI
//

/// A tappable control.
///
/// ```swift
/// Button("Increment") { count += 1 }
/// Button(action: reset) { Label() }
/// ```
public struct Button<Label: View>: View {

    let action: () -> Void
    let label: Label

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPressed = false

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public var body: some View {
        label
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.color(tint.opacity(isPressed ? 0.65 : 1)))
            )
            .opacity(isEnabled ? 1 : 0.4)
            ._hitTarget(HitTarget(
                isEnabled: isEnabled,
                // Pressed state is visual only — the action fires on release
                // inside the button, so dragging off cancels, as it should.
                onPress: { _ in isPressed = true },
                onRelease: { _, inside in
                    isPressed = false
                    if inside { action() }
                }
            ))
    }
}

extension Button where Label == Text {
    public init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}
