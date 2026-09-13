//
//  LayoutModifiers.swift
//  NucleantSwiftUI
//
//  Every modifier is a `_ModifierView`: one wrapped child plus the node kind
//  it builds. Writing them this way rather than as a `ViewModifier` each keeps
//  the type explosion down — `Text().padding().background(…)` is three nested
//  generics, not three nested `ModifiedContent`s over three modifier types.
//

/// A view that wraps one child and contributes a specific layout node.
public struct _ModifierView<Content: View>: View {
    var content: Content
    let makeContent: @MainActor (inout BuildContext) -> any NodeContent
    /// A modifier that changes the environment for its subtree does it here,
    /// before the child is built.
    let modifyEnvironment: (@MainActor (inout EnvironmentValues) -> Void)?
    /// What the closures were built from, for telling two applications of
    /// the same modifier apart — `.padding(16)` is `["padding", insets]`,
    /// the name first because two different modifiers over the same content
    /// are the same type. `nil` when the modifier holds something
    /// incomparable (a gesture's action), which makes it never equivalent,
    /// and so always rebuilt.
    let key: AnyHashable?

    init(
        content: Content,
        key: AnyHashable? = nil,
        environment: (@MainActor (inout EnvironmentValues) -> Void)? = nil,
        node: @escaping @MainActor (inout BuildContext) -> any NodeContent
    ) {
        self.content = content
        self.key = key
        self.makeContent = node
        self.modifyEnvironment = environment
    }

    public var body: Never { bodyUnavailable() }
}

extension _ModifierView {
    /// `Row().padding()` is one expression, so the builder stamps the
    /// outermost wrapper; the identity belongs to the view inside.
    public var _viewID: ViewID {
        get { content._viewID }
        set { content._viewID = newValue }
    }

    public func _isEquivalent(to other: _ModifierView<Content>) -> Bool {
        guard let key, key == other.key else { return false }
        return _areEquivalent(content, other.content)
    }
}

extension _ModifierView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        modifyEnvironment?(&inner.environment)
        let nodeContent = makeContent(&inner)
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(content: nodeContent, children: [child])
    }
}

/// A view that wraps a child *and* a decoration — background and overlay.
public struct _DecoratedView<Content: View, Decoration: View>: View {
    var content: Content
    let decoration: Decoration
    let order: DecorationContent.Order
    let alignment: Alignment

    public var body: Never { bodyUnavailable() }

    /// As `_ModifierView`: the stamp belongs to the content.
    public var _viewID: ViewID {
        get { content._viewID }
        set { content._viewID = newValue }
    }

    public func _isEquivalent(to other: _DecoratedView<Content, Decoration>) -> Bool {
        order == other.order && alignment == other.alignment
            && _areEquivalent(content, other.content)
            && _areEquivalent(decoration, other.decoration)
    }
}

extension _DecoratedView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // Two positional slots — `DecorationContent` reads `children[0]` and
        // `children[1]` directly and must not see them flattened.
        let contentNode = context.child(0) { ctx in buildNode(content, &ctx) }
        let decorationNode = context.child(1) { ctx in buildNode(decoration, &ctx) }
        return ViewNode(
            content: DecorationContent(order: order, alignment: alignment),
            children: [contentNode, decorationNode]
        )
    }
}

// MARK: - Frame

extension View {
    /// A fixed frame.
    public func frame(
        width: Double? = nil,
        height: Double? = nil,
        alignment: Alignment = .center
    ) -> some View {
        _ModifierView(content: self, key: ["frame", width, height, alignment] as [AnyHashable]) { _ in
            FrameContent(
                width: width,
                height: height,
                minWidth: nil,
                maxWidth: nil,
                minHeight: nil,
                maxHeight: nil,
                alignment: alignment
            )
        }
    }

    /// A flexible frame. `maxWidth: .infinity` means "take everything offered".
    public func frame(
        minWidth: Double? = nil,
        idealWidth: Double? = nil,
        maxWidth: Double? = nil,
        minHeight: Double? = nil,
        idealHeight: Double? = nil,
        maxHeight: Double? = nil,
        alignment: Alignment = .center
    ) -> some View {
        _ModifierView(
            content: self,
            key: ["frame", minWidth, idealWidth, maxWidth, minHeight, idealHeight, maxHeight, alignment] as [AnyHashable]
        ) { _ in
            FrameContent(
                width: idealWidth,
                height: idealHeight,
                minWidth: minWidth,
                maxWidth: maxWidth,
                minHeight: minHeight,
                maxHeight: maxHeight,
                alignment: alignment
            )
        }
    }
}

extension View {
    /// Sizes this view to a fraction of the space its parent offers —
    /// `relativeSize(width: 0.4)` is "40% of the available width".
    ///
    /// A `nil` axis is left to the child.
    public func relativeSize(width: Double? = nil, height: Double? = nil) -> some View {
        _ModifierView(content: self, key: ["relativeSize", width, height] as [AnyHashable]) { _ in
            RelativeSizeContent(widthFraction: width, heightFraction: height)
        }
    }
}

// MARK: - Padding

extension View {
    public func padding(_ insets: EdgeInsets) -> some View {
        _ModifierView(content: self, key: ["padding", insets] as [AnyHashable]) { _ in PaddingContent(insets: insets) }
    }

    public func padding(_ edges: Edge.Set = .all, _ amount: Double = 16) -> some View {
        padding(EdgeInsets(edges, amount))
    }

    public func padding(_ amount: Double) -> some View {
        padding(EdgeInsets(amount))
    }

    public func padding(horizontal: Double = 0, vertical: Double = 0) -> some View {
        padding(EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal))
    }
}

extension View {
    /// Keeps this view in the tree — identity, `@State`, scroll offsets —
    /// while taking it off screen. Used by `NavigationStack` for the screens
    /// beneath the top one.
    public func _parked(_ isParked: Bool) -> some View {
        _ModifierView(content: self, key: ["parked", isParked] as [AnyHashable]) { _ in
            ParkedContent(isParked: isParked)
        }
    }
}
