//
//  ContextMenu.swift
//  NucleantSwiftUI
//
//  `.contextMenu(menuItems:)`. The modifier marks a node with the items;
//  `ViewHost` opens the menu — on a right click, or a press held still on a
//  touch host — as an overlay above the tree, built from `ContextMenuOverlay`
//  below. Inside it a `Button` draws as a menu row, a `Menu` as a row that
//  opens a submenu beside it, and a `Divider` as a rule; choosing a row or
//  pressing anywhere outside closes it.
//

import Observation

extension View {

    /// Adds a menu that opens on a right click (a long press on touch).
    ///
    /// ```swift
    /// TrackRow(track)
    ///     .contextMenu {
    ///         Button("Duplicate") { duplicate(track) }
    ///         Button("Rename…") { rename(track) }
    ///         Divider()
    ///         Button("Delete") { delete(track) }
    ///     }
    /// ```
    ///
    /// The items are views: `Button`s become rows, `Menu`s rows that open a
    /// submenu beside them, `Divider` a rule between them, and `if` works
    /// as in any builder. A row runs its action and closes the menu; a
    /// press anywhere else closes it without one.
    public func contextMenu<MenuItems: View>(
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        let items = AnyView(menuItems())
        return _ModifierView(content: self) { context in
            ContextMenuContent(source: ContextMenuSource(
                isEnabled: context.environment.isEnabled,
                items: items
            ))
        }
    }
}

/// A node with a context menu.
@MainActor
final class ContextMenuSource {
    let isEnabled: Bool
    let items: AnyView

    init(isEnabled: Bool, items: AnyView) {
        self.isEnabled = isEnabled
        self.items = items
    }
}

/// `.contextMenu(menuItems:)`.
struct ContextMenuContent: NodeContent {
    let source: ContextMenuSource

    var contextMenuSource: ContextMenuSource? { source.isEnabled ? source : nil }
}

// MARK: - The open menu

/// The menu that is open, as the views inside it see it. `Button` and
/// `Menu` read this from the environment to draw as rows, to open and close
/// submenus as the pointer moves over them, and to close the whole menu
/// once an action has run.
///
/// `@Observable`, so the overlay's `body` — which reads `submenus` — is
/// rebuilt when a submenu opens or closes, and only it.
@MainActor @Observable
public final class ContextMenuController {
    let items: AnyView
    private let close: @MainActor () -> Void

    /// One open submenu: what it holds, the row it hangs off, and how deep
    /// that row is (the root panel's rows are level 0).
    struct Submenu: Identifiable {
        let id: ObjectIdentifier
        let items: AnyView
        let anchor: Rect
        let level: Int
    }

    /// Open submenus, outermost first. At most one per level.
    private(set) var submenus: [Submenu] = []

    init(items: AnyView, close: @escaping @MainActor () -> Void) {
        self.items = items
        self.close = close
    }

    /// Close the menu.
    public func dismiss() {
        close()
    }

    /// The pointer is over a row at `level`: any submenu hanging off that
    /// panel or a deeper one closes, as on macOS. A row that is itself a
    /// `Menu` then opens its own with `openSubmenu`.
    func hoverRow(level: Int) {
        guard submenus.contains(where: { $0.level >= level }) else { return }
        submenus.removeAll { $0.level >= level }
    }

    /// Open the submenu of the `Menu` row identified by `id`, beside
    /// `anchor` (the row's frame, window coordinates).
    func openSubmenu(id: ObjectIdentifier, items: AnyView, anchor: Rect, level: Int) {
        guard !isSubmenuOpen(id) else { return }
        submenus.removeAll { $0.level >= level }
        submenus.append(Submenu(id: id, items: items, anchor: anchor, level: level))
    }

    func isSubmenuOpen(_ id: ObjectIdentifier) -> Bool {
        submenus.contains { $0.id == id }
    }
}

extension ContextMenuController: ViewInput {
    /// One controller per opening; the same object is the same menu. What
    /// changes inside it is tracked by observation.
    public func _isEquivalent(to other: ContextMenuController) -> Bool {
        self === other
    }
}

private struct ContextMenuKey: EnvironmentKey {
    static let defaultValue: ContextMenuController? = nil
}

/// How deep the panel a row sits in is: 0 for the menu itself, 1 for a
/// submenu, and so on.
private struct MenuLevelKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// The context menu this view is an item of, if it is one.
    public var contextMenu: ContextMenuController? {
        get { self[ContextMenuKey.self] }
        set { self[ContextMenuKey.self] = newValue }
    }

    var menuLevel: Int {
        get { self[MenuLevelKey.self] }
        set { self[MenuLevelKey.self] = newValue }
    }
}

/// What `ViewHost` puts over the tree while a menu is open: a scrim that
/// closes it on any press, the panel of items at the anchor, and a panel
/// for each open submenu beside the row it hangs off.
struct ContextMenuOverlay: View {
    let anchor: Point
    let controller: ContextMenuController

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Pressing outside closes the menu and goes no further — the
            // press is not delivered to what is under the scrim, as on macOS.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ._hitTarget(HitTarget(onPress: { _ in controller.dismiss() }))

            ContextMenuPanel(items: controller.items, level: 0)
                ._anchored(at: anchor)

            ForEach(controller.submenus) { submenu in
                // To the right of its row, top edges aligned (the panel's
                // padding pulled back so the first rows line up); to the
                // left instead when the right has no room.
                ContextMenuPanel(items: submenu.items, level: submenu.level + 1)
                    ._anchored(
                        at: Point(x: submenu.anchor.maxX + 1, y: submenu.anchor.minY - ContextMenuPanel.inset),
                        flippingTo: submenu.anchor.minX - 1
                    )
            }
        }
        .environment(\.contextMenu, controller)
    }
}

/// The items in a column, on a panel.
struct ContextMenuPanel: View {
    let items: AnyView
    let level: Int

    /// The panel's padding — what a submenu is offset by so its first row
    /// sits level with the row that opened it.
    static let inset = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            items
        }
        .padding(Self.inset)
        .frame(minWidth: 160, alignment: .leading)
        .background(Color.secondaryBackground)
        .border(Color.separator, cornerRadius: 8)
        .cornerRadius(8)
        .environment(\.menuLevel, level)
    }
}

extension View {
    /// The look shared by every row of a menu: full width, lit in the tint
    /// while the pointer is over it or pressing it.
    func _menuRow(isLit: Bool, isEnabled: Bool, tint: Color) -> some View {
        self
            .font(.system(size: 14))
            .foregroundColor(isLit ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.color(isLit ? tint : .clear))
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension View {
    /// Places this view at its own size with its top-left corner at
    /// `anchor`, pulled back inside the parent's rect if it would overflow.
    /// With `flippingTo`, a view that would overflow on the right is put
    /// with its *right* edge there instead — how a submenu swaps sides.
    func _anchored(at anchor: Point, flippingTo flipX: Double? = nil) -> some View {
        _ModifierView(content: self, key: ["anchored", anchor.x, anchor.y, flipX] as [AnyHashable?]) { _ in
            AnchoredContent(anchor: anchor, flipX: flipX)
        }
    }

    /// Writes this view's placed frame (window coordinates) into `box` on
    /// every layout pass, for a view that needs to know where it is — a
    /// `Menu` row opening its submenu beside itself.
    func _recordFrame(into box: FrameBox) -> some View {
        _ModifierView(content: self) { _ in FrameRecorderContent(box: box) }
    }
}

/// `_anchored(at:flippingTo:)`: fills what it is offered, and puts its
/// child, at the child's own size, at the anchor — or as close to it as
/// still fits.
struct AnchoredContent: NodeContent {
    let anchor: Point
    let flipX: Double?

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        var size = child.sizeThatFits(.unspecified)
        size.width = min(size.width, rect.width)
        size.height = min(size.height, rect.height)
        var x = anchor.x
        if let flipX, x + size.width > rect.maxX, flipX - size.width >= rect.minX {
            x = flipX - size.width
        }
        let origin = Point(
            x: min(max(x, rect.minX), rect.maxX - size.width),
            y: min(max(anchor.y, rect.minY), rect.maxY - size.height)
        )
        // Proposed its final size, so a row with `maxWidth: .infinity`
        // stretches to the panel rather than to its own label.
        child.place(
            in: Rect(origin: origin, size: size),
            proposal: ProposedSize(size),
            context: context,
            into: &list
        )
    }
}

/// Where a node was last placed, for a view to read back.
@MainActor
class FrameBox {
    var frame: Rect = .zero
    init() {}
}

/// `_recordFrame(into:)`.
struct FrameRecorderContent: NodeContent {
    let box: FrameBox

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        box.frame = rect
        node.singleChild?.place(in: rect, proposal: proposal, context: context, into: &list)
    }
}
