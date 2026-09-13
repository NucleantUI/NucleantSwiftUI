//
//  Geometry.swift
//  NucleantSwiftUI
//
//  Doubles throughout, matching the rest of the Nucleant stack (SIMD2<Double>
//  frames in PyNucleantUI's layout), rather than SDLUI's Float RectF.
//

public struct Point: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = Point()
}

public struct Size: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }

    public static let zero = Size()

    /// The extent along one axis — lets the stack maths read a size the same
    /// way it reads a `ProposedSize`.
    public subscript(axis: Axis) -> Double {
        get { axis == .horizontal ? width : height }
        set {
            if axis == .horizontal { width = newValue } else { height = newValue }
        }
    }
}

public struct Rect: Hashable, Sendable {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: .init(x: x, y: y), size: .init(width: width, height: height))
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var x: Double { origin.x }
    public var y: Double { origin.y }
    public var width: Double { size.width }
    public var height: Double { size.height }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }

    public var center: Point { .init(x: midX, y: midY) }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func insetBy(_ insets: EdgeInsets) -> Rect {
        Rect(
            x:      x + insets.leading,
            y:      y + insets.top,
            width:  Swift.max(0, width  - insets.leading - insets.trailing),
            height: Swift.max(0, height - insets.top     - insets.bottom)
        )
    }

    public func insetBy(_ amount: Double) -> Rect {
        insetBy(EdgeInsets(amount))
    }

    /// The intersection with `other`, or a zero-size rect at this origin when
    /// they don't overlap. Used for clipping a child into its parent.
    public func intersection(_ other: Rect) -> Rect {
        let x0 = Swift.max(minX, other.minX)
        let y0 = Swift.max(minY, other.minY)
        let x1 = Swift.min(maxX, other.maxX)
        let y1 = Swift.min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return Rect(x: x0, y: y0, width: 0, height: 0) }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

public struct EdgeInsets: Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(_ all: Double) {
        self.init(top: all, leading: all, bottom: all, trailing: all)
    }

    public static let zero = EdgeInsets()

    public var horizontal: Double { leading + trailing }
    public var vertical: Double { top + bottom }

    public init(_ edges: Edge.Set, _ amount: Double) {
        self.init(
            top:      edges.contains(.top)      ? amount : 0,
            leading:  edges.contains(.leading)  ? amount : 0,
            bottom:   edges.contains(.bottom)   ? amount : 0,
            trailing: edges.contains(.trailing) ? amount : 0
        )
    }
}

public enum Edge: Int8, CaseIterable, Sendable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Sendable {
        public var rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }

        public static let top      = Set(rawValue: 1 << 0)
        public static let leading  = Set(rawValue: 1 << 1)
        public static let bottom   = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)

        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical:   Set = [.top, .bottom]
        public static let all:        Set = [.top, .leading, .bottom, .trailing]
    }
}

/// The axis a stack lays out along. Named `Axis` to match SwiftUI; the
/// engine-side equivalent in PyNucleantUI is `Orientation`.
public enum Axis: Hashable, Sendable {
    case horizontal
    case vertical

    public struct Set: OptionSet, Sendable {
        public var rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1 << 0)
        public static let vertical   = Set(rawValue: 1 << 1)
    }

    /// The axis at right angles to this one.
    public var cross: Axis { self == .horizontal ? .vertical : .horizontal }
}

public struct Angle: Hashable, Sendable {
    public var radians: Double

    public init(radians: Double) { self.radians = radians }
    public init(degrees: Double) { self.radians = degrees * .pi / 180 }

    public var degrees: Double { radians * 180 / .pi }

    public static let zero = Angle(radians: 0)
    public static func radians(_ value: Double) -> Angle { .init(radians: value) }
    public static func degrees(_ value: Double) -> Angle { .init(degrees: value) }
}

/// A point in a view's unit coordinate space — (0,0) top-leading to (1,1)
/// bottom-trailing. Gradients and effect anchors are expressed in it.
public struct UnitPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero         = UnitPoint(x: 0,   y: 0)
    public static let topLeading   = UnitPoint(x: 0,   y: 0)
    public static let top          = UnitPoint(x: 0.5, y: 0)
    public static let topTrailing  = UnitPoint(x: 1,   y: 0)
    public static let leading      = UnitPoint(x: 0,   y: 0.5)
    public static let center       = UnitPoint(x: 0.5, y: 0.5)
    public static let trailing     = UnitPoint(x: 1,   y: 0.5)
    public static let bottomLeading  = UnitPoint(x: 0,   y: 1)
    public static let bottom         = UnitPoint(x: 0.5, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1,   y: 1)

    /// This unit point resolved into `rect`.
    public func resolved(in rect: Rect) -> Point {
        .init(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}
