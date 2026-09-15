//
//  Spacer.swift
//  NucleantSwiftUI
//

/// Expands along the stack's axis, pushing its siblings apart.
@View
public struct Spacer: View {
    public let minLength: Double

    public init(minLength: Double = 0) {
        self.minLength = minLength
    }

    public var body: Never { bodyUnavailable() }
}

extension Spacer: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // The axis is stamped in by whichever stack builds it — see
        // `HStack`/`VStack`. Outside a stack a spacer just fills.
        ViewNode(content: SpacerContent(minLength: minLength, axis: context.stackAxis))
    }
}

/// A hairline rule across the stack's cross axis.
@View
public struct Divider: View {
    public init() {}

    public var body: Never { bodyUnavailable() }
}

extension Divider: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // 1 point thick along the stack's axis, filling the other. Outside a
        // stack it behaves as a horizontal rule, the same default SwiftUI has.
        let axis = context.stackAxis ?? .vertical
        let color = context.environment.foregroundColor.opacity(0.25)
        return ViewNode(content: DividerContent(axis: axis, color: color))
    }
}

/// Sized by the stack it sits in: thin across the stack's axis, full width of
/// the cross axis.
struct DividerContent: NodeContent {
    let axis: Axis
    let color: Color

    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        axis == self.axis ? .fixed : .content
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        var size = Size(width: 1, height: 1)
        size[axis] = 1
        size[axis.cross] = proposal[axis.cross] ?? 1
        return size
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        var path = Path()
        path.addRect(rect)
        list.append(.shape(ShapeDraw(
            path: path,
            bounds: rect,
            fill: .color(context.resolve(color)),
            transform: context.transform,
            clip: context.clip,
            clipCornerRadius: context.clipCornerRadius
        )))
    }
}
