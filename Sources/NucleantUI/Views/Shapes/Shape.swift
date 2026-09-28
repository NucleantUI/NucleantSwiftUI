//
//  Shape.swift
//  NucleantUI
//

/// A 2D shape that can be filled or stroked.
///
/// Unlike SwiftUI's, `path(in:)` returns a path in *absolute* coordinates —
/// the rect passed in is where the shape was placed, so building straight into
/// it saves a translate per shape.
///
/// Every shape is `Animatable`: one that exposes `animatableData` is drawn
/// at each value in between when a change to it animates — its path is
/// made again every frame, nothing is rebuilt.
@MainActor
public protocol Shape: Animatable, View {
    func path(in rect: Rect) -> Path
}

/// A shape used directly as a view fills with the current foreground color,
/// the same default SwiftUI applies.
extension Shape {
    public var body: _ShapeView<Self> {
        _ShapeView(shape: self, fill: nil, stroke: nil, strokeStyle: StrokeStyle(), fillsWithForeground: true)
    }
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

/// A shape with its paint resolved. Every `Shape` becomes one of these —
/// used bare, through its `body`, filled with the environment's foreground
/// color.
@View
public struct _ShapeView<S: Shape>: View {
    let shape: S
    let fill: ShapeStyle?
    let stroke: ShapeStyle?
    let strokeStyle: StrokeStyle
    /// Fill with the foreground color in effect, rather than `fill`.
    var fillsWithForeground: Bool = false

    public var body: Never { bodyUnavailable() }
}

extension _ShapeView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let drawn = context.drawnShape(shape)
        let fill = fillsWithForeground ? .color(context.environment.foregroundColor) : self.fill
        return ViewNode(content: ShapeContent(
            makePath: { rect in drawn().path(in: rect) },
            fill: fill,
            stroke: stroke,
            strokeStyle: strokeStyle,
            idealSize: nil,
            animatedFill: context.animatedStyle(.fill, fill),
            animatedStroke: context.animatedStyle(.stroke, stroke)
        ))
    }
}

/// The built-in shapes, which are nodes themselves rather than a body.
extension Shape {
    func makeShapeNode(_ context: inout BuildContext) -> ViewNode {
        _ShapeView(shape: self, fill: nil, stroke: nil, strokeStyle: StrokeStyle(), fillsWithForeground: true)
            .makeNode(&context)
    }
}
