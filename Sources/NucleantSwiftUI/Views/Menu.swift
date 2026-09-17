//
//  Menu.swift
//  NucleantSwiftUI
//

/// A control that opens a menu of items — or, inside a context menu, a row
/// that opens a submenu beside it.
///
/// ```swift
/// Menu("Presets") {                       // a dropdown button
///     Button("Mute") { level = 0 }
///     Button("Full") { level = 1 }
/// }
///
/// row.contextMenu {
///     Menu("Set level") {                 // a submenu row
///         Button("Mute") { level = 0 }
///         Button("Full") { level = 1 }
///     }
///     Divider()
///     Button("Delete") { … }
/// }
/// ```
///
/// A submenu opens as the pointer moves over its row (a tap, on touch)
/// and closes when the pointer moves onto another row of the panel it
/// hangs off. The dropdown form opens its items under the control,
/// dismissed like any menu.
public struct Menu<Label: View, Content: View>: View {

    let content: Content
    let label: Label

    /// Identity across rebuilds, and where the row was placed — the
    /// submenu hangs off this frame. A class so the same handle survives
    /// the rebuilds that hovering causes.
    @State private var handle = MenuHandle()

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.contextMenu) private var contextMenu
    @Environment(\.menuLevel) private var menuLevel
    @Environment(\.menuPresenter) private var presenter
    @State private var isPressed = false
    @State private var isHovered = false

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        if let contextMenu {
            submenuRow(in: contextMenu)
        } else {
            dropdown
        }
    }

    /// A row with a chevron; its submenu is open while the row is lit.
    private func submenuRow(in menu: ContextMenuController) -> some View {
        let isOpen = menu.isSubmenuOpen(handle.id)
        let open = { menu.openSubmenu(id: handle.id, items: AnyView(content), anchor: handle.frame, level: menuLevel) }
        return HStack(spacing: 8) {
            label
            Spacer()
            Text("›")
        }
        ._menuRow(isLit: isHovered || isOpen, isEnabled: isEnabled, tint: tint)
        ._recordFrame(into: handle)
        .onHover { hovering in
            isHovered = hovering
            if hovering { open() }
        }
        // A tap opens it too — the only way on touch, where nothing hovers.
        ._hitTarget(HitTarget(isEnabled: isEnabled, onRelease: { _, inside in if inside { open() } }))
    }

    /// A button that opens the items as a menu under itself.
    private var dropdown: some View {
        HStack(spacing: 6) {
            label
            // The chevron turned to point down — the bundled face has no
            // "▾" of its own.
            Text("›").rotationEffect(.degrees(90))
        }
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
            onPress: { _ in isPressed = true },
            onRelease: { _, inside in
                isPressed = false
                if inside { presenter?.present(AnyView(content)) }
            }
        ))
    }
}

extension Menu where Label == Text {
    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

/// See `Menu.handle`.
@MainActor
final class MenuHandle: FrameBox {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    override init() {}
}

/// How a `Menu` outside any context menu opens: the host presents the items
/// under the control that was just released.
@MainActor
public final class MenuPresenter {
    private let show: @MainActor (AnyView) -> Void

    init(show: @escaping @MainActor (AnyView) -> Void) {
        self.show = show
    }

    /// Open `items` as a menu under the control being released.
    public func present(_ items: AnyView) {
        show(items)
    }
}

extension MenuPresenter: ViewInput {
    /// One per host, for its lifetime.
    public func _isEquivalent(to other: MenuPresenter) -> Bool {
        self === other
    }
}

private struct MenuPresenterKey: EnvironmentKey {
    static let defaultValue: MenuPresenter? = nil
}

extension EnvironmentValues {
    /// The host's way of opening a menu, set for every tree it builds.
    public var menuPresenter: MenuPresenter? {
        get { self[MenuPresenterKey.self] }
        set { self[MenuPresenterKey.self] = newValue }
    }
}
