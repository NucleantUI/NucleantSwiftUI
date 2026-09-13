//
//  DisplayList.swift
//  NucleantSwiftUI
//
//  The flat, absolute-coordinate output of one layout pass. Everything above
//  this line is view/layout code that never names ThorVG; everything below it
//  (`ThorDisplayRenderer`) only ever sees this.
//

/// A resolved path in absolute window coordinates.
public struct Path: Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        case move(Point)
        case line(Point)
        case cubic(control1: Point, control2: Point, end: Point)
        case close
        /// A rect with per-axis corner radii — `append_rect` handles this in
        /// one call, and doing it here keeps ThorVG's own rounding maths.
        case rect(Rect, radiusX: Double, radiusY: Double)
        case ellipse(center: Point, radiusX: Double, radiusY: Double)
    }

    public var elements: [Element] = []

    public init() {}

    public init(_ build: (inout Path) -> Void) {
        build(&self)
    }

    public var isEmpty: Bool { elements.isEmpty }

    public mutating func move(to point: Point) { elements.append(.move(point)) }
    public mutating func addLine(to point: Point) { elements.append(.line(point)) }

    public mutating func addCurve(to end: Point, control1: Point, control2: Point) {
        elements.append(.cubic(control1: control1, control2: control2, end: end))
    }

    public mutating func closeSubpath() { elements.append(.close) }

    public mutating func addRect(_ rect: Rect, cornerRadius: Double = 0) {
        elements.append(.rect(rect, radiusX: cornerRadius, radiusY: cornerRadius))
    }

    public mutating func addRoundedRect(_ rect: Rect, radiusX: Double, radiusY: Double) {
        elements.append(.rect(rect, radiusX: radiusX, radiusY: radiusY))
    }

    public mutating func addEllipse(in rect: Rect) {
        elements.append(.ellipse(
            center: rect.center,
            radiusX: rect.width / 2,
            radiusY: rect.height / 2
        ))
    }

    /// Every element shifted — how a shape built in a view's local space
    /// becomes absolute.
    public func offsetBy(dx: Double, dy: Double) -> Path {
        guard dx != 0 || dy != 0 else { return self }
        func shift(_ p: Point) -> Point { .init(x: p.x + dx, y: p.y + dy) }
        var copy = self
        copy.elements = elements.map { element in
            switch element {
            case .move(let p):  return .move(shift(p))
            case .line(let p):  return .line(shift(p))
            case .cubic(let c1, let c2, let end):
                return .cubic(control1: shift(c1), control2: shift(c2), end: shift(end))
            case .close:        return .close
            case .rect(let r, let rx, let ry):
                return .rect(r.offsetBy(dx: dx, dy: dy), radiusX: rx, radiusY: ry)
            case .ellipse(let c, let rx, let ry):
                return .ellipse(center: shift(c), radiusX: rx, radiusY: ry)
            }
        }
        return copy
    }
}

/// One paint operation. `bounds` is the shape's own rect — gradients resolve
/// their `UnitPoint`s against it, so it travels with the command rather than
/// being recomputed from the path.
public struct ShapeDraw: Sendable {
    public var path: Path
    public var bounds: Rect
    public var fill: ShapeStyle?
    public var stroke: ShapeStyle?
    public var strokeStyle: StrokeStyle
    public var transform: Transform
    public var clip: Rect?
    public var clipCornerRadius: Double

    public init(
        path: Path,
        bounds: Rect,
        fill: ShapeStyle? = nil,
        stroke: ShapeStyle? = nil,
        strokeStyle: StrokeStyle = StrokeStyle(),
        transform: Transform = .identity,
        clip: Rect? = nil,
        clipCornerRadius: Double = 0
    ) {
        self.path = path
        self.bounds = bounds
        self.fill = fill
        self.stroke = stroke
        self.strokeStyle = strokeStyle
        self.transform = transform
        self.clip = clip
        self.clipCornerRadius = clipCornerRadius
    }
}

public struct TextDraw: Sendable {
    public var string: String
    /// The box the text is laid out in — absolute, already sized by layout.
    public var frame: Rect
    public var font: Font
    public var color: Color
    public var alignment: TextAlignment
    public var lineLimit: Int?
    /// True when the string is wider than the box it was given, so the
    /// renderer should truncate with an ellipsis. Decided at layout time,
    /// where the natural width is already known — asking the renderer to work
    /// it out would mean measuring the same string twice.
    public var isTruncated: Bool
    public var transform: Transform
    public var clip: Rect?
    public var clipCornerRadius: Double

    public init(
        string: String,
        frame: Rect,
        font: Font,
        color: Color,
        alignment: TextAlignment = .leading,
        lineLimit: Int? = nil,
        isTruncated: Bool = false,
        transform: Transform = .identity,
        clip: Rect? = nil,
        clipCornerRadius: Double = 0
    ) {
        self.string = string
        self.frame = frame
        self.font = font
        self.color = color
        self.alignment = alignment
        self.lineLimit = lineLimit
        self.isTruncated = isTruncated
        self.transform = transform
        self.clip = clip
        self.clipCornerRadius = clipCornerRadius
    }
}

public enum DrawCommand: Sendable {
    case shape(ShapeDraw)
    case text(TextDraw)
}

/// The commands produced by one layout pass, in paint order.
public struct DisplayList: Sendable {
    public private(set) var commands: [DrawCommand] = []

    public init() {}

    public mutating func append(_ command: DrawCommand) {
        commands.append(command)
    }

    public var isEmpty: Bool { commands.isEmpty }
}

/// The ambient state a node draws under: inherited opacity, clip and
/// transform, plus the environment-driven defaults a leaf needs. Passed down
/// `place`, never up.
public struct DrawContext: Sendable {
    public var opacity: Double = 1
    public var transform: Transform = .identity
    public var clip: Rect?
    public var clipCornerRadius: Double = 0

    public init() {}

    /// `color` faded by the inherited opacity — every leaf applies this rather
    /// than the renderer setting per-paint opacity, so gradients fade too.
    func resolve(_ color: Color) -> Color {
        opacity >= 1 ? color : color.opacity(opacity)
    }

    func resolve(_ style: ShapeStyle) -> ShapeStyle {
        guard opacity < 1 else { return style }
        switch style {
        case .color(let color):
            return .color(color.opacity(opacity))
        case .linearGradient(let gradient, let start, let end):
            return .linearGradient(faded(gradient), startPoint: start, endPoint: end)
        case .radialGradient(let gradient, let center, let startRadius, let endRadius):
            return .radialGradient(faded(gradient), center: center, startRadius: startRadius, endRadius: endRadius)
        }
    }

    private func faded(_ gradient: Gradient) -> Gradient {
        Gradient(stops: gradient.stops.map {
            Gradient.Stop(color: $0.color.opacity(opacity), location: $0.location)
        })
    }

    /// Narrow the clip to `rect` — intersecting, so an inner clip can never
    /// widen an outer one.
    func clipped(to rect: Rect, cornerRadius: Double = 0) -> DrawContext {
        var copy = self
        copy.clip = clip.map { $0.intersection(rect) } ?? rect
        // Only one rounded clip is tracked; an inner rounding replaces an
        // outer one rather than compositing two rounded masks.
        copy.clipCornerRadius = cornerRadius > 0 ? cornerRadius : (clip == nil ? 0 : clipCornerRadius)
        return copy
    }
}
