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
public struct ShapeDraw: Equatable, Sendable {
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

public struct TextDraw: Equatable, Sendable {
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
    /// False when the whole string fits the box on one line, so the renderer
    /// must not wrap it: ThorVG's own layout can find a label a fraction
    /// wider than the summed advances did, and would break a fitted single
    /// line in two.
    public var wraps: Bool
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
        wraps: Bool = true,
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
        self.wraps = wraps
        self.transform = transform
        self.clip = clip
        self.clipCornerRadius = clipCornerRadius
    }
}

/// A bitmap stretched into `frame`.
public struct ImageDraw: Equatable, Sendable {
    public var image: RasterImage
    public var frame: Rect
    /// The inherited opacity — a bitmap has no colours to fade at layout
    /// time, so it carries the factor for the renderer to apply.
    public var opacity: Double
    public var transform: Transform
    public var clip: Rect?
    public var clipCornerRadius: Double

    public init(
        image: RasterImage,
        frame: Rect,
        opacity: Double = 1,
        transform: Transform = .identity,
        clip: Rect? = nil,
        clipCornerRadius: Double = 0
    ) {
        self.image = image
        self.frame = frame
        self.opacity = opacity
        self.transform = transform
        self.clip = clip
        self.clipCornerRadius = clipCornerRadius
    }
}

public enum DrawCommand: Equatable, Sendable {
    case shape(ShapeDraw)
    case text(TextDraw)
    case image(ImageDraw)
}

/// The commands produced by one layout pass, in paint order.
///
/// `Equatable` so a `.shader` layer can tell whether the view under it drew
/// anything different since its canvas was last rasterized — comparing two
/// lists is far cheaper than a ThorVG pass that comes out identical.
public struct DisplayList: Equatable, Sendable {
    public private(set) var commands: [DrawCommand] = []

    public init() {}

    public mutating func append(_ command: DrawCommand) {
        commands.append(command)
    }

    public mutating func append(contentsOf other: DisplayList) {
        commands.append(contentsOf: other.commands)
    }

    public var isEmpty: Bool { commands.isEmpty }

    /// The same list drawn `(dx, dy)` further along — how a view's absolute
    /// commands become local to its own render node, so that the node's
    /// content compares equal across passes that only *moved* the view.
    func translated(dx: Double, dy: Double) -> DisplayList {
        guard dx != 0 || dy != 0 else { return self }
        var copy = DisplayList()
        copy.commands.reserveCapacity(commands.count)
        for command in commands {
            copy.commands.append(command.translated(dx: dx, dy: dy))
        }
        return copy
    }
}

/// The ambient state a node draws under: inherited opacity, clip and
/// transform, plus the environment-driven defaults a leaf needs. Passed down
/// `place`, never up.
public struct DrawContext: Sendable {
    public var opacity: Double = 1
    public var transform: Transform = .identity
    public var clip: Rect?
    public var clipCornerRadius: Double = 0
    /// The appearance dynamic colors resolve against here.
    public var colorScheme: ColorScheme = .light

    /// True while the list being filled is a *capture* that wants every
    /// pixel of the subtree in it — a `.shader` layer, a `.hidden()` view's
    /// discard, a drag snapshot. A `.drawingGroup()` inside then draws
    /// inline instead of into a node of its own, which would composite over
    /// the capture rather than into it.
    var flattensRenderNodes = false

    /// The clip of the containers above the nearest enclosing render node,
    /// which took it out of `clip` so its content compares equal as it
    /// scrolls under the clip and cuts it at the composite instead. A node
    /// or shader slot inside is cut by this and by `clip` both.
    var nodeClip: Rect?

    /// What a render node or shader slot placed here is cut to at the
    /// composite: every clip above it, whichever node took it over.
    var compositeClip: Rect? {
        switch (clip, nodeClip) {
        case (let clip?, let outer?): return clip.intersection(outer)
        case (let clip?, nil): return clip
        case (nil, let outer?): return outer
        case (nil, nil): return nil
        }
    }

    public init() {}

    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    /// `color` under this scheme, faded by the inherited opacity — every leaf
    /// applies this rather than the renderer setting per-paint opacity, so
    /// gradients fade too.
    func resolve(_ color: Color) -> Color {
        let resolved = color.resolved(for: colorScheme)
        return opacity >= 1 ? resolved : resolved.opacity(opacity)
    }

    func resolve(_ style: ShapeStyle) -> ShapeStyle {
        switch style {
        case .color(let color):
            return .color(resolve(color))
        case .linearGradient(let gradient, let start, let end):
            return .linearGradient(faded(gradient), startPoint: start, endPoint: end)
        case .radialGradient(let gradient, let center, let startRadius, let endRadius):
            return .radialGradient(faded(gradient), center: center, startRadius: startRadius, endRadius: endRadius)
        }
    }

    private func faded(_ gradient: Gradient) -> Gradient {
        Gradient(stops: gradient.stops.map {
            Gradient.Stop(color: resolve($0.color), location: $0.location)
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
