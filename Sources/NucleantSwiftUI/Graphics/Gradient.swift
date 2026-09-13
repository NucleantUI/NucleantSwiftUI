//
//  Gradient.swift
//  NucleantSwiftUI
//

public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: Double

        public init(color: Color, location: Double) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]

    public init(stops: [Stop]) {
        self.stops = stops
    }

    /// Evenly spaced stops, the common case.
    public init(colors: [Color]) {
        guard colors.count > 1 else {
            self.stops = colors.map { Stop(color: $0, location: 0) }
            return
        }
        let step = 1.0 / Double(colors.count - 1)
        self.stops = colors.enumerated().map { Stop(color: $1, location: Double($0) * step) }
    }
}

/// How a shape is painted. `ShapeStyle` in SwiftUI is a protocol; here it is a
/// closed enum because the renderer has to switch on it to build the matching
/// `Tvg_Gradient`, and the set of fills ThorVG offers is itself closed.
public enum ShapeStyle: Hashable, Sendable {
    case color(Color)
    case linearGradient(Gradient, startPoint: UnitPoint, endPoint: UnitPoint)
    case radialGradient(Gradient, center: UnitPoint, startRadius: Double, endRadius: Double)

    /// A representative flat color — used where a gradient can't be applied
    /// (text outlines, 1px borders).
    public var flatColor: Color {
        switch self {
        case .color(let color):
            return color
        case .linearGradient(let gradient, _, _), .radialGradient(let gradient, _, _, _):
            return gradient.stops.first?.color ?? .clear
        }
    }

    public var isClear: Bool {
        if case .color(let color) = self { return color.isClear }
        return false
    }
}

extension ShapeStyle {
    public static func linearGradient(
        colors: [Color],
        startPoint: UnitPoint = .top,
        endPoint: UnitPoint = .bottom
    ) -> ShapeStyle {
        .linearGradient(Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }
}

/// A named line style for strokes.
public struct StrokeStyle: Hashable, Sendable {
    public var lineWidth: Double
    public var lineCap: LineCap
    public var lineJoin: LineJoin
    public var dash: [Double]
    public var dashPhase: Double

    public init(
        lineWidth: Double = 1,
        lineCap: LineCap = .butt,
        lineJoin: LineJoin = .miter,
        dash: [Double] = [],
        dashPhase: Double = 0
    ) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.dash = dash
        self.dashPhase = dashPhase
    }
}

public enum LineCap: Hashable, Sendable {
    case butt, round, square
}

public enum LineJoin: Hashable, Sendable {
    case miter, round, bevel
}
