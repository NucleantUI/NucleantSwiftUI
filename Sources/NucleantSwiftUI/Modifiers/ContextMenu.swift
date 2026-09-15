//
//  ContextMenu.swift
//  NucleantSwiftUI
//
//  `.contextMenu(menuItems:)`. The modifier marks a node with the items;
//  `ViewHost` opens the menu — on a right click, or a press held still on a
//  touch host — as an overlay above the tree, built from `ContextMenuOverlay`
//  below. Inside it a `Button` draws as a menu row and a `Divider` as a
//  rule, and choosing a row or pressing anywhere outside closes it.
//

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
    /// The items are views: `Button`s become rows, `Divider` a rule between
    /// them, and `if` works as in any builder. A row runs its action and
    /// closes the menu; a press anywhere else closes it without one.
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

/// The menu that is open, as the views inside it see it: `Button` reads
/// this from the environment to draw itself as a row and to close the menu
/// once its action has run.
@MainActor
public final class ContextMenuController {
    let items: AnyView
    private let close: @MainActor () -> Void

    init(items: AnyView, close: @escaping @MainActor () -> Void) {
        self.items = items
        self.close = close
    }

    /// Close the menu.
    public func dismiss() {
        close()
    }
}

extension ContextMenuController: ViewInput {
    /// One controller per opening; the same object is the same menu.
    public func _isEquivalent(to other: ContextMenuController) -> Bool {
        self === other
    }
}

private struct ContextMenuKey: EnvironmentKey {
    static let defaultValue: ContextMenuController? = nil
}

extension EnvironmentValues {
    /// The context menu this view is an item of, if it is one.
    public var contextMenu: ContextMenuController? {
        get { self[ContextMenuKey.self] }
        set { self[ContextMenuKey.self] = newValue }
    }
}

/// What `ViewHost` puts over the tree while a menu is open: a scrim that
/// closes it on any press, and the panel of items at the anchor.
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

            ContextMenuPanel(items: controller.items)
                ._anchored(at: anchor)
        }
        .environment(\.contextMenu, controller)
    }
}

/// The items in a column, on a panel.
struct ContextMenuPanel: View {
    let items: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            items
        }
        .padding(5)
        .frame(minWidth: 160, alignment: .leading)
        .background(Color.secondaryBackground)
        .border(Color.separator, cornerRadius: 8)
        .cornerRadius(8)
    }
}

extension View {
    /// Places this view at its own size with its top-left corner at
    /// `anchor`, pulled back inside the parent's rect if it would overflow.
    func _anchored(at anchor: Point) -> some View {
        _ModifierView(content: self, key: ["anchored", anchor.x, anchor.y] as [AnyHashable]) { _ in
            AnchoredContent(anchor: anchor)
        }
    }
}

/// `_anchored(at:)`: fills what it is offered, and puts its child, at the
/// child's own size, at the anchor — or as close to it as still fits.
struct AnchoredContent: NodeContent {
    let anchor: Point

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild else { return }
        var size = child.sizeThatFits(.unspecified)
        size.width = min(size.width, rect.width)
        size.height = min(size.height, rect.height)
        let origin = Point(
            x: min(max(anchor.x, rect.minX), rect.maxX - size.width),
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
