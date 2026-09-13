//
//  Transform.swift
//  NucleantSwiftUI
//
//  A 2D affine transform in the same row layout ThorVG's `Tvg_Matrix` uses
//  (e11 e12 e13 / e21 e22 e23), so the renderer can hand one straight over.
//

public struct Transform: Hashable, Sendable {
    public var e11: Double, e12: Double, e13: Double
    public var e21: Double, e22: Double, e23: Double

    public init(
        e11: Double, e12: Double, e13: Double,
        e21: Double, e22: Double, e23: Double
    ) {
        self.e11 = e11; self.e12 = e12; self.e13 = e13
        self.e21 = e21; self.e22 = e22; self.e23 = e23
    }

    public static let identity = Transform(
        e11: 1, e12: 0, e13: 0,
        e21: 0, e22: 1, e23: 0
    )

    public var isIdentity: Bool { self == .identity }

    public static func translation(x: Double, y: Double) -> Transform {
        Transform(e11: 1, e12: 0, e13: x, e21: 0, e22: 1, e23: y)
    }

    public static func scale(x: Double, y: Double) -> Transform {
        Transform(e11: x, e12: 0, e13: 0, e21: 0, e22: y, e23: 0)
    }

    public static func rotation(_ angle: Angle) -> Transform {
        let c = Foundation_cos(angle.radians)
        let s = Foundation_sin(angle.radians)
        return Transform(e11: c, e12: -s, e13: 0, e21: s, e22: c, e23: 0)
    }

    /// `self` applied *after* `other` — i.e. the matrix product `self × other`.
    public func concatenating(_ other: Transform) -> Transform {
        Transform(
            e11: e11 * other.e11 + e12 * other.e21,
            e12: e11 * other.e12 + e12 * other.e22,
            e13: e11 * other.e13 + e12 * other.e23 + e13,
            e21: e21 * other.e11 + e22 * other.e21,
            e22: e21 * other.e12 + e22 * other.e22,
            e23: e21 * other.e13 + e22 * other.e23 + e23
        )
    }

    public func apply(to point: Point) -> Point {
        .init(
            x: e11 * point.x + e12 * point.y + e13,
            y: e21 * point.x + e22 * point.y + e23
        )
    }

    /// The inverse, or `nil` for a degenerate (zero-determinant) transform —
    /// what hit testing needs to map a window point back into a rotated or
    /// scaled view's own space.
    public func inverted() -> Transform? {
        let determinant = e11 * e22 - e12 * e21
        guard determinant != 0 else { return nil }
        let inverse = 1 / determinant
        let a =  e22 * inverse
        let b = -e12 * inverse
        let c = -e21 * inverse
        let d =  e11 * inverse
        return Transform(
            e11: a, e12: b, e13: -(a * e13 + b * e23),
            e21: c, e22: d, e23: -(c * e13 + d * e23)
        )
    }

    /// A transform that rotates/scales about `anchor` rather than the origin.
    public static func around(_ anchor: Point, _ transform: Transform) -> Transform {
        Transform.translation(x: anchor.x, y: anchor.y)
            .concatenating(transform)
            .concatenating(Transform.translation(x: -anchor.x, y: -anchor.y))
    }
}

// Foundation is otherwise unused in this file; the two trig calls are wrapped
// so the import stays local to them.
import func Foundation.cos
import func Foundation.sin

@inline(__always) private func Foundation_cos(_ x: Double) -> Double { Foundation.cos(x) }
@inline(__always) private func Foundation_sin(_ x: Double) -> Double { Foundation.sin(x) }
