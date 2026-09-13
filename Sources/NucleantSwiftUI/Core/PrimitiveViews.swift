//
//  PrimitiveViews.swift
//  NucleantSwiftUI
//
//  The structural views `@ViewBuilder` produces, plus type erasure. None of
//  them draw anything themselves — each contributes children to the layout
//  tree, transparently where a stack should treat those children as its own
//  (see `ViewNode.isTransparent`).
//

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

    public init<V: View>(_ view: V) {
        self.makeErasedNode = { context in buildNode(view, &context) }
    }

    public var body: Never { bodyUnavailable() }
}

extension AnyView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        makeErasedNode(&context)
    }
}

extension View {
    /// The failure a primitive view's `body` raises. Spelled out once rather
    /// than repeated at every call site.
    func bodyUnavailable() -> Never {
        preconditionFailure("\(Self.self) is a primitive view — its body is never evaluated.")
    }
}
