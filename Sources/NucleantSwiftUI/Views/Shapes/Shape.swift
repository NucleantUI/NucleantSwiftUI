//
//  Shape.swift
//  NucleantSwiftUI
//

/// A 2D shape that can be filled or stroked.
///
/// Unlike SwiftUI's, `path(in:)` returns a path in *absolute* coordinates —
/// the rect passed in is where the shape was placed, so building straight into
/// it saves a translate per shape.
@MainActor
public protocol Shape: View {
    func path(in rect: Rect) -> Path
}

/// A shape used directly as a view fills with the current foreground color,
/// the same default SwiftUI applies.
extension Shape where Body == Never {
    public var body: Never { bodyUnavailable() }
}

extension Shape {
    /// Fill this shape with a style.
    public func fill(_ style: ShapeStyle) -> some View {
        _ShapeView(shape: self, fill: style, stroke: nil, strokeStyle: StrokeStyle())
    }

    public func fill(_ color: Color) -> some View {
        fill(.color(color))
    }

    /// Stroke this shape's outline.
    public func stroke(_ style: ShapeStyle, lineWidth: Double = 1) -> some View {
        _ShapeView(
            shape: self,
            fill: nil,
            stroke: style,
            strokeStyle: StrokeStyle(lineWidth: lineWidth)
        )
    }

    public func stroke(_ color: Color, lineWidth: Double = 1) -> some View {
        stroke(.color(color), lineWidth: lineWidth)
    }

    public func stroke(_ color: Color, style: StrokeStyle) -> some View {
        _ShapeView(shape: self, fill: nil, stroke: .color(color), strokeStyle: style)
    }
}

/// A shape with its paint resolved. Every `Shape` becomes one of these — used
/// bare, the shape's own `makeNode` wraps itself in one with the environment's
/// foreground color.
@View
public struct _ShapeView<S: Shape>: View {
    let shape: S
    let fill: ShapeStyle?
    let stroke: ShapeStyle?
    let strokeStyle: StrokeStyle

    public var body: Never { bodyUnavailable() }
}

extension _ShapeView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let shape = self.shape
        return ViewNode(content: ShapeContent(
            makePath: { rect in shape.path(in: rect) },
            fill: fill,
            stroke: stroke,
            strokeStyle: strokeStyle,
            idealSize: nil
        ))
    }
}

/// Using a shape directly as a view: filled with the foreground color.
extension Shape {
    func makeShapeNode(_ context: inout BuildContext) -> ViewNode {
        let shape = self
        return ViewNode(content: ShapeContent(
            makePath: { rect in shape.path(in: rect) },
            fill: .color(context.environment.foregroundColor),
            stroke: nil,
            strokeStyle: StrokeStyle(),
            idealSize: nil
        ))
    }
}
