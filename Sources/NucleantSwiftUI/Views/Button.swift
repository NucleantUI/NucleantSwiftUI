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
    @Environment(\.contextMenu) private var contextMenu
    @State private var isPressed = false

    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public var body: some View {
        if let contextMenu {
            menuRow(in: contextMenu)
        } else {
            standalone
        }
    }

    /// As an item of a context menu: a full-width row, lit in the tint
    /// while pressed, that runs the action and closes the menu.
    private func menuRow(in menu: ContextMenuController) -> some View {
        label
            .font(.system(size: 14))
            .foregroundColor(isPressed ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.color(isPressed ? tint : .clear))
            )
            .opacity(isEnabled ? 1 : 0.4)
            ._hitTarget(HitTarget(
                isEnabled: isEnabled,
                onPress: { _ in isPressed = true },
                onRelease: { _, inside in
                    isPressed = false
                    guard inside else { return }
                    action()
                    menu.dismiss()
                }
            ))
    }

    private var standalone: some View {
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
