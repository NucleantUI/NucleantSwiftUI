//
//  BasicShapes.swift
//  NucleantSwiftUI
//

/// A rectangle filling its frame.
@View
public struct Rectangle: Shape {
    public init(_viewID: ViewID = #viewID) { self._viewID = _viewID }

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addRect(rect)
        return path
    }
}

extension Rectangle: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode { makeShapeNode(&context) }
}

public enum RoundedCornerStyle: Hashable, Sendable {
    case circular
    case continuous
}

/// A rectangle with rounded corners.
@View
public struct RoundedRectangle: Shape {
    public var cornerRadius: Double
    public var style: RoundedCornerStyle

    public init(cornerRadius: Double, style: RoundedCornerStyle = .circular, _viewID: ViewID = #viewID) {
        self.cornerRadius = cornerRadius
        self.style = style
        self._viewID = _viewID
    }

    public func path(in rect: Rect) -> Path {
        var path = Path()
        // Clamp: ThorVG draws a radius larger than half the shorter side as an
        // overlapping arc rather than a capsule.
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        path.addRect(rect, cornerRadius: radius)
        return path
    }
}

extension RoundedRectangle: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode { makeShapeNode(&context) }
}

/// A circle inscribed in its frame — SwiftUI's `Circle` uses the *smaller*
/// dimension and centres, which is what keeps it round in a non-square box.
@View
public struct Circle: Shape {
    public init(_viewID: ViewID = #viewID) { self._viewID = _viewID }

    public func path(in rect: Rect) -> Path {
        let diameter = min(rect.width, rect.height)
        let square = Rect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        var path = Path()
        path.addEllipse(in: square)
        return path
    }
}

extension Circle: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode { makeShapeNode(&context) }
}

/// An ellipse filling its frame.
@View
public struct Ellipse: Shape {
    public init(_viewID: ViewID = #viewID) { self._viewID = _viewID }

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addEllipse(in: rect)
        return path
    }
}

extension Ellipse: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode { makeShapeNode(&context) }
}

/// A rounded rectangle whose corner radius is half its shorter side.
@View
public struct Capsule: Shape {
    public var style: RoundedCornerStyle

    public init(style: RoundedCornerStyle = .circular, _viewID: ViewID = #viewID) {
        self.style = style
        self._viewID = _viewID
    }

    public func path(in rect: Rect) -> Path {
        var path = Path()
        path.addRect(rect, cornerRadius: min(rect.width, rect.height) / 2)
        return path
    }
}

extension Capsule: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode { makeShapeNode(&context) }
}

/// A caller-supplied path, built in the view's own coordinate space (origin at
/// the frame's top-left) and moved into place by the framework.
public struct PathShape: Shape {
    let build: (Size) -> Path

    public init(_ build: @escaping (Size) -> Path) {
        self.build = build
    }

    public func path(in rect: Rect) -> Path {
        build(rect.size).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

extension PathShape: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode { makeShapeNode(&context) }
}
