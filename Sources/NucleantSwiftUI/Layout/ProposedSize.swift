//
//  ProposedSize.swift
//  NucleantSwiftUI
//
//  The same contract as PyNucleantUI's `ProposedViewSize` (and SwiftUI's):
//  either axis may be `nil` — *unspecified* — meaning the container isn't
//  constraining it, so the child picks its own extent there.
//

public struct ProposedSize: Hashable, Sendable {
    public var width: Double?
    public var height: Double?

    public init(width: Double?, height: Double?) {
        self.width = width
        self.height = height
    }

    public init(_ size: Size) {
        self.width = size.width
        self.height = size.height
    }

    public static let zero        = ProposedSize(width: 0, height: 0)
    public static let unspecified = ProposedSize(width: nil, height: nil)
    public static let infinity    = ProposedSize(width: .infinity, height: .infinity)

    public subscript(axis: Axis) -> Double? {
        get { axis == .horizontal ? width : height }
        set {
            if axis == .horizontal { width = newValue } else { height = newValue }
        }
    }

    /// Fill any unspecified axis from `size`, yielding a concrete size.
    public func replacingUnspecifiedDimensions(by size: Size = .zero) -> Size {
        .init(width: width ?? size.width, height: height ?? size.height)
    }

    /// A copy with one axis replaced.
    public func replacing(_ axis: Axis, with value: Double?) -> ProposedSize {
        var copy = self
        copy[axis] = value
        return copy
    }
}
