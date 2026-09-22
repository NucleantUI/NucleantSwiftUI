//
//  ThorContext.swift
//  NucleantSwiftUI
//
import NucleantThorVG

/// A render node's ThorVG canvas, as a `ThorCanvas` view's closures see it.
///
/// `add` / `remove` / `insert` come from `ThorGPUCanvas`; paints added to it
/// belong to it until removed, so hold them through `TCShape` / `TCScene`
/// (which keep a reference of their own) to touch them again later. Sizes
/// and coordinates are canvas pixels — `scale` is how many of those a point
/// is, for anything laid out in points.
public final class ThorContext: ThorGPUCanvas, @unchecked Sendable {
    public var base: Tvg_Canvas

    /// Backing-store pixels per point.
    public internal(set) var scale: Double = 1

    public init(base: Tvg_Canvas) {
        self.base = base
    }
}
