//
//  TCShape.swift
//  NucleantSwiftUI
//
import NucleantThorVG

/// A ThorVG shape an author holds across frames.
///
/// Owns its paint: a reference is taken on creation and given back on
/// deinit, so the canvas dropping the shape (`tvg_canvas_remove`, or the
/// node's canvas being recycled) does not free it under the author's feet —
/// it can be added to the next canvas when `onInit` runs again.
public final class TCShape: ThorShape {
    public var base: Tvg_Paint

    public init(base: Tvg_Paint = tvg_shape_new()) {
        self.base = base
        _ = tvg_paint_ref(base)
    }

    deinit {
        _ = tvg_paint_unref(base, true)
    }
}
