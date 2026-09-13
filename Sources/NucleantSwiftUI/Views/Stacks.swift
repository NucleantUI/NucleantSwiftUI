//
//  Stacks.swift
//  NucleantSwiftUI
//

/// Stacks its children vertically.
@View
public struct VStack<Content: View>: View {
    public let alignment: HorizontalAlignment
    public let spacing: Double?
    public let content: Content

    public init(
        alignment: HorizontalAlignment = .center,
        spacing: Double? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { bodyUnavailable() }
}

extension VStack: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        inner.stackAxis = .vertical
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: StackContent(
                axis: .vertical,
                spacing: spacing,
                horizontalAlignment: alignment,
                verticalAlignment: .top
            ),
            children: [child]
        )
    }
}

/// Stacks its children horizontally.
@View
public struct HStack<Content: View>: View {
    public let alignment: VerticalAlignment
    public let spacing: Double?
    public let content: Content

    public init(
        alignment: VerticalAlignment = .center,
        spacing: Double? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    public var body: Never { bodyUnavailable() }
}

extension HStack: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        inner.stackAxis = .horizontal
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: StackContent(
                axis: .horizontal,
                spacing: spacing,
                horizontalAlignment: .leading,
                verticalAlignment: alignment
            ),
            children: [child]
        )
    }
}

/// Overlays its children, back to front.
@View
public struct ZStack<Content: View>: View {
    public let alignment: Alignment
    public let content: Content

    public init(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: Never { bodyUnavailable() }
}

extension ZStack: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // A ZStack is not a stack in the `stackAxis` sense — a `Spacer` inside
        // one should fill, not stretch along an axis — so the axis is cleared.
        var inner = context
        inner.stackAxis = nil
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(content: ZStackContent(alignment: alignment), children: [child])
    }
}
