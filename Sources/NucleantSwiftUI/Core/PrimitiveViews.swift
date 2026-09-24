//
//  PrimitiveViews.swift
//  NucleantSwiftUI
//
//  The structural views `@ViewBuilder` produces, plus type erasure. None of
//  them draw anything themselves — each contributes children to the layout
//  tree, transparently where a stack should treat those children as its own
//  (see `ViewNode.isTransparent`).
//

import NucleantWindow

/// A view that displays nothing.
public struct EmptyView: View {
    public init() {}
    public var body: Never { bodyUnavailable() }
}

extension EmptyView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        ViewNode(content: GroupContent(), children: [])
    }
}

/// Several child views produced by one `@ViewBuilder` block.
public struct TupleView<each T: View>: View {
    public let value: (repeat each T)

    public init(_ value: (repeat each T)) {
        self.value = (repeat each value)
    }

    public var body: Never { bodyUnavailable() }
}

extension TupleView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var children: [ViewNode] = []
        var index = 0
        for view in repeat (each value) {
            children.append(context.child(index) { ctx in buildNode(view, &ctx) })
            index += 1
        }
        return ViewNode(content: GroupContent(), children: children)
    }
}

/// `@ViewBuilder`'s `for` loop support.
public struct _ViewArray<Content: View>: View {
    public let elements: [Content]

    public init(_ elements: [Content]) {
        self.elements = elements
    }

    public var body: Never { bodyUnavailable() }
}

extension _ViewArray: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let children = elements.enumerated().map { index, element in
            context.child(index) { ctx in buildNode(element, &ctx) }
        }
        return ViewNode(content: GroupContent(), children: children)
    }
}

/// One of two branches of an `if`/`else` in a `@ViewBuilder`.
public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View {
    @frozen
    public enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }

    public let storage: Storage

    public init(storage: Storage) {
        self.storage = storage
    }

    public var body: Never { bodyUnavailable() }
}

extension _ConditionalContent: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // Each branch gets its own path slot, so flipping the condition
        // discards the other branch's `@State` instead of aliasing onto it.
        switch storage {
        case .trueContent(let content):
            return context.child(0) { ctx in buildNode(content, &ctx) }
        case .falseContent(let content):
            return context.child(1) { ctx in buildNode(content, &ctx) }
        }
    }
}

/// `Optional` is a view when its wrapped type is — a bare `if` in a builder.
extension Optional: ViewInput where Wrapped: View {}
extension Optional: View where Wrapped: View {
    public var body: Never { bodyUnavailable() }
}

extension Optional: BuiltinView where Wrapped: View {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        switch self {
        case .some(let wrapped):
            return context.child(0) { ctx in buildNode(wrapped, &ctx) }
        case .none:
            return ViewNode(content: GroupContent(), children: [])
        }
    }
}

/// A type-erased view.
public struct AnyView: View {
    /// The build closure over the erased value — capturing it is what lets the
    /// concrete type stay out of `AnyView`'s own signature while the node
    /// builder still sees it.
    let makeErasedNode: @MainActor (inout BuildContext) -> ViewNode
    /// The same, for the erased value's menu rows (see `MenuItems.swift`).
    let lowerMenuItems: @MainActor (inout MenuLowering) -> [MenuBar.Item]

    public init<V: View>(_ view: V) {
        self.makeErasedNode = { context in buildNode(view, &context) }
        self.lowerMenuItems = { lowering in menuItems(of: view, &lowering) }
    }

    public var body: Never { bodyUnavailable() }
}

extension AnyView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        makeErasedNode(&context)
    }
}

/// What `ViewHost` actually builds: the app's root, and over it whatever
/// the host is presenting — popovers, a context menu. Two fixed slots, so
/// the root keeps its path (`[0]`) whether or not anything is over it, and
/// a presentation coming and going only rebuilds slot `[1]`.
struct _HostRoot: View {
    let content: AnyView
    let overlay: AnyView?
    /// Where slot `[1]` paints — read by the host after the pass.
    let capture: OverlayCapture

    var body: Never { bodyUnavailable() }
}

/// What the overlay slot drew this pass, kept apart from the window's list:
/// the host composites it as the topmost render node, so a menu opened over
/// a `.drawingGroup()` or a `Shader` is over it, not under it. `order` is
/// the paint position reserved for that node as the slot began — so a node
/// *inside* the overlay (a shader in a popover) composites over it.
@MainActor
final class OverlayCapture {
    var list = DisplayList()
    var order: Int?
    /// The nodes placed inside the overlay, for the host to file its
    /// images around — see `RenderBoundaries.Frame`.
    var frame: RenderBoundaries.Frame?
}

/// Slot `[1]`: the open popovers, and over them the context menu if one is
/// open — a menu opened from a popover's content sits above it.
struct _HostOverlay: View {
    let popovers: PopoverPresenter
    let contextMenu: ContextMenuOverlay?

    var body: some View {
        ZStack(alignment: .topLeading) {
            PopoverOverlay(presenter: popovers)
            if let contextMenu {
                contextMenu
            }
        }
    }
}

extension _HostRoot: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let content = context.child(0) { ctx in buildNode(self.content, &ctx) }
        let overlay = context.child(1) { ctx in buildNode(self.overlay, &ctx) }
        return ViewNode(content: HostRootContent(capture: capture), children: [content, overlay])
    }
}

/// Both slots get the whole window. By `children`, not `layoutChildren`:
/// an empty overlay is a transparent group that flattening would drop,
/// shifting the slots. Slot `[0]` paints into the window's list; slot `[1]`
/// into the capture, for the host to composite last.
struct HostRootContent: NodeContent {
    let capture: OverlayCapture

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard node.children.count == 2 else {
            for child in node.children {
                child.place(in: rect, proposal: proposal, context: context, into: &list)
            }
            return
        }
        node.children[0].place(in: rect, proposal: proposal, context: context, into: &list)
        capture.list = DisplayList()
        capture.frame = nil
        let host = ShaderHost.current
        capture.order = host?.renderNodes.nextPaintOrder()
        if let order = capture.order {
            host?.boundaries.beginFrame(primaryOrder: order)
        }
        node.children[1].place(in: rect, proposal: proposal, context: context, into: &capture.list)
        if capture.order != nil {
            capture.frame = host?.boundaries.endFrame()
        }
    }
}

extension View {
    /// The failure a primitive view's `body` raises. Spelled out once rather
    /// than repeated at every call site.
    func bodyUnavailable() -> Never {
        preconditionFailure("\(Self.self) is a primitive view — its body is never evaluated.")
    }
}
